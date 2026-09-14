/* fs.c - filesystem commands over the IEC serial bus.
 *
 * The directory commands (dir/ls/pwd) read the magic "$" file on the drive and
 * decode the BASIC-program-shaped listing it returns: a load address, then one
 * "line" per entry (a 2-byte link, a 2-byte line number that doubles as the
 * block count, and PETSCII text ending in NUL), terminated by a $00,$00 link.
 * dir_begin/dir_line/dir_end below stream that, and each command interprets the
 * per-line text its own way. The drive sends names/types as PETSCII, which our
 * ASCII-consistent CHROUT renders as-is (uppercase names show uppercase).
 */
#include "shell.h"
#include "iec.h"

#define CR    0x0D
#define CLEAR 0x93
#define TEXT_COLOR ((unsigned char *)0x0286)    /* KERNAL current text color */
#define WHITE      0x01

/* TAB-completion cache valid flag ($CE00; docs/TAB-COMPLETION.md). The dir
   overlay fills the cache as ls/dir draw and re-validates it; everything that
   changes the directory (or where we're looking) clears the flag here so
   readline never completes from a stale listing. */
#define TAB_CACHE_OK (*(unsigned char *)0xCE00)

/* in c_io.s: jump to a loaded program; does not return. */
void run_program(unsigned int addr);

/* in src/rbcp/launch.s: copy the RBCP library to RAM, drive a bank swap to
   the stock-ROM slot, and JMP through (FFFC) so stock KERNAL does its own
   reset/init. The loaded program (if any) stays in RAM at load_start --
   `RUN` from BASIC after the prompt picks it up. Never returns. Only
   meaningful on a One ROM firmware that includes the user/host-control
   plugin (cfg/onerom-stock.json); without it, the protocol calls are inert
   and the JMP through (FFFC) just re-enters our own shell. */
void rbcp_launch_stock(void);

/* Start address of the most recently loaded program, or 0 if none. Lives in
   BSS, so it is zero at boot. */
/* Start/end of the most recently loaded program, or 0 if none.
 *
 * These ARE the disk-bank mailbox cells, not copies of them: `load` and `fload`
 * both run in the bank now, so the bank is what learns the addresses, and a
 * resident copy has to be refreshed by somebody. That copying is exactly what
 * broke -- when the resident load/fload thunks were deleted for data-driven
 * dispatch, only `run <name>` still copied, so `fload x` then a bare `run` said
 * "nothing loaded", and `load x` then `basic` cold-swapped instead of handing
 * the program over. Sharing the cells removes the copy, and with it the chance
 * of it going stale again.
 *
 * reset.s zeroes them at boot: page 3 is power-on garbage, and a nonzero
 * load_start would make a bare `run` launch nothing at all. */
#define load_start (*(unsigned int *)0x039A)
#define load_end   (*(unsigned int *)0x039C)

/* The device ls/load/run talk to; `device <n>` changes it. Initialized (DATA,
   restored on reset), not BSS, so it boots as 8. */
static unsigned char default_device = 8;

/* Optional friendly names for devices 8..15 (index = device - 8); empty means
   none. `device <n> <name>` sets one, `device <n>` alone keeps it. BSS, so
   all start empty. */
#define DEV_MIN     8
#define DEV_MAX     15
#define DEVNAME_MAX 10
/* Row size is a POWER OF TWO (not DEVNAME_MAX + 1 = 11) so indexing is a shift
   rather than a 16-bit multiply -- an 11-byte row pulled cc65's mul runtime
   into the resident ROM. The extra 5 bytes/row of BSS is the cheaper trade.
   The files overlay walks these rows through the $02F6 pointer, so DEVNAME_ROW
   is also the stride it must use. */
#define DEVNAME_ROW 16
static char device_name[DEV_MAX - DEV_MIN + 1][DEVNAME_ROW];

/* The remembered name for the current default device, or "" (none / out of
   the 8..15 range). */
static const char *current_device_name(void)
{
    if (default_device >= DEV_MIN && default_device <= DEV_MAX)
        return device_name[default_device - DEV_MIN];
    return "";
}

void print_uint(unsigned int n);        /* non-static: shell.c's nv diag uses it */

/* Print "<dev>[ <name>]" -- the device prefix the shell draws left of the
   prompt character (main() in shell.c calls this before the prompt). chrout
   uses the current text color. The device number goes through print_uint so
   this stays free of a 16-bit divide too (see print_uint). */
void print_device_prefix(void)
{
    const char *name = current_device_name();

    print_uint(default_device);
    if (name[0]) {                      /* "8: meatloaf" -- the unit number plus
                                           the user-given or fetched identity */
        chrout(':');
        chrout(' ');
        puts_raw(name);
    }
}

/* Print an unsigned int in decimal. Done by repeated subtraction of powers of
   ten rather than n/10 % 10: a 16-bit divide would pull cc65's udiv/umod (~96
   bytes of runtime) into the resident ROM, and this is the only divide left in
   the resident C, so avoiding it drops them entirely. */
static const unsigned int print_uint_pow10[4] = { 10000, 1000, 100, 10 };

void print_uint(unsigned int n)
{
    unsigned char i, d, started = 0;
    unsigned int p;

    for (i = 0; i < 4; ++i) {
        p = print_uint_pow10[i];
        d = 0;
        while (n >= p) { n -= p; ++d; }
        if (d || started) {
            chrout('0' + d);
            started = 1;
        }
    }
    chrout('0' + (unsigned char)n);     /* units digit (also prints "0" for 0) */
}

/* Print "usage: <rest>" + newline. Shared so the "usage: " prefix isn't
   duplicated as a separate string literal in every command's arg check (cc65
   doesn't merge identical literals). */
static void usage(const char *rest)
{
    puts_raw("usage: ");
    puts_raw(rest);
    chrout(CR);
}




/* (device's bus probe moved into the files overlay -- it uses the KERNAL OPEN
   shim there; see do_device / device_present_ov in src/overlays/files.c.) */
/* dir / ls / pwd / fload -- the DISK BANK (src/banks/, docs/ROM-EXPANSION.md).
   The whole disk cluster -- these three, the Epyx protocol, and the fload/run
   fast path -- lives in an 8KB image the One ROM serves at $A000 in place of
   this ROM's BASIC half, so none of it occupies the 16KB budget. The resident
   side is just these thunks: fill the mailbox at $02D0, then bank_call() the
   matching $A000 JMP-table entry (src/rbcp/launch.s).

   The commands still reach the bus through the $FF80 services table (src/svc.s)
   -- while a bank runs, this ROM's BASIC half is swapped out, so the KERNAL
   half's stubs and services are the only resident code it can call. */
extern unsigned char __fastcall__ bank_call(unsigned char entry);

/* bank_call already distinguishes WHY it failed; say so rather than throwing it
   away. 1 = nothing answered (no One ROM, or LOAD/SWITCH_SLOT refused), 2 = a
   set WAS switched in but carried the wrong image (mis-numbered flash set).
   The two have completely different causes, and on hardware this line is the
   only evidence available. */
static void report_no_bank(unsigned char rc)
{
    puts_raw("bank unavailable (");
    chrout('0' + rc);
    chrout(')');
    chrout(CR);
}

/* Shared disk-bank mailbox in the unused tape buffer, clear of cd's $0340 path
   scratch. See src/banks/disk_bank.c, which must agree byte for byte. */
#define DM_NLEN     (*(unsigned char *)0x0370)
#define DM_NAME     ((unsigned char *)0x0371)
#define DM_NAME_MAX 40
#define DM_STAT     (*(unsigned char *)0x0399)
#define DM_START    (*(unsigned int *)0x039A)
#define DM_END      (*(unsigned int *)0x039C)

#define DM_OK        0
#define DM_NO_DEVICE 1

#define DB_CMD  (*(unsigned char *)0x02D0)       /* 0 dir, 1 ls, 2 pwd */
#define DB_DEV  (*(unsigned char *)0x02D1)
#define DB_NLEN (*(unsigned char *)0x02D2)
#define DB_NAME ((unsigned char *)0x02D3)

/* Run bank entry `entry`, the one piece of resident code every bank command
   shares (data-driven dispatch -- see shell.h). It publishes what a bank
   command cannot reach for itself:

     - the default device and its remembered name, which stay resident because
       every disk command and the prompt read them;
     - argc and a pointer to argv, so the bank parses its OWN arguments. argv
       entries point into `line` in RAM, which the bank can follow.

   With this, a bank command needs no resident thunk at all: just its row in
   the dispatch table. */
#define BD_ARGC (*(unsigned char *)0x03A0)
#define BD_ARGV (*(char ***)0x03A1)

unsigned char bank_try(unsigned char entry, int argc, char *argv[])
{
    const char *name;
    unsigned char n = 0;

    /* Addresses of resident state a bank must update in place: the default
       device and the per-device name table stay resident because the prompt and
       every disk command read them. */
    *(unsigned char **)0x02F4 = &default_device;
    *(char **)0x02F6 = &device_name[0][0];
    /* The dispatch table, for `help` -- it lists whatever is registered, and
       only the resident side knows where the table is. (Shares bytes with
       mailbox arg 2; commands that use that arg do not read this.) */
    *(const void **)0x02E4 = (const void *)shell_commands;
    *(unsigned char *)0x02E6 = shell_command_count;

    DB_DEV = default_device;
    name = current_device_name();
    while (name[n] && n < 16) {
        DB_NAME[n] = name[n];
        ++n;
    }
    DB_NLEN = n;

    BD_ARGC = (unsigned char)argc;
    BD_ARGV = argv;

    return bank_call(entry);
}

void bank_dispatch(unsigned char entry, int argc, char *argv[])
{
    unsigned char rc = bank_try(entry, argc, argv);

    if (rc != 0)
        report_no_bank(rc);
}


/* edit - open the editor that suits the file.
 *
 * TWO constraints shape this, and between them they leave one design.
 *
 * (1) The choice cannot be made inside either editor, because A BANK CANNOT CALL
 *     ANOTHER BANK -- the switch pulls the caller's code out from under the CPU.
 *     So whatever decides has to run before the bank call.
 *
 * (2) It should not be a bank call of its own. The first attempt put a sniff
 *     entry in the disk bank -- the usual instinct here, since the 16KB image is
 *     the scarce thing -- and the decisive problem is TESTABILITY: only one bank
 *     is served at a time, so `edit` needing the disk bank AND then an editor
 *     bank cannot complete in VICE at all, and the routing (the half a user
 *     notices, because it opens the wrong editor) could only ever be checked on
 *     hardware. Resident, `edit` makes exactly one bank call, and
 *     test_hex::test_edit_picks_the_hex_editor_for_a_binary can seed the hex bank
 *     and watch a binary actually arrive there.
 *
 *     (A second reason was claimed here first -- that the extra bank call paid an
 *     RBCP timeout and blew the suite's wall time to 1299s. That measurement was
 *     contaminated: the run also carried a real bug of mine, `edit` with no name
 *     printing usage instead of opening a new document, so a dozen tests were
 *     waiting out their retry loops, and the machine had slept mid-run. The cost
 *     of the second swap was never cleanly measured; testability is the reason
 *     that stands.)
 *
 * So the sniff is resident. It costs ~420 bytes of the 16KB image, which is the
 * honest price of being able to test the thing.
 */
#define SNIFFN 48               /* enough to judge by, cheap enough not to feel */

/* 0 = text or BASIC (the text editor), 1 = binary (the hex editor).
   Errs towards the TEXT editor: it is the one that reports a missing file, a
   wrong device and a drive error properly, so anything unreadable lands
   somewhere that explains itself rather than in a hex dump of nothing.

   One pass, no buffer: only the first four bytes need keeping (for the BASIC
   test) and everything else is just counted, which is ~100 bytes less code than
   reading into an array and walking it again. */
static unsigned char sniff_binary(const char *name)
{
    unsigned char h[4];
    unsigned char n = 0, c, good = 0;

    iec_set_fa(default_device);
    iec_set_sa(2);                      /* a data channel */
    /* By name only, no type suffix: a suffix makes the drive report the other
       kind as missing, and we must look at PRG and SEQ alike. */
    iec_setname(name);
    iec_open();
    if (iec_status() & ST_NODEV) {
        iec_close();
        iec_clrchn();
        return 0;
    }
    iec_chkin();
    while (n < SNIFFN) {
        c = iec_getbyte();
        if (iec_status() & (ST_TIMEOUT | ST_NODEV))
            break;
        if ((iec_status() & ST_EOI) && !c)
            break;                      /* a 1541 sends a real last byte; a
                                           Meatloaf synthesises a $00 with
                                           nothing behind it -- do not count it */
        if (n < 4)
            h[n] = c;
        /* Count from byte 2: in a PRG the first two are the load address and
           usually are not text, which would drag a short text PRG over the line
           by themselves. CR/LF/TAB and printable ASCII count as text -- CBM text
           uses $41-$5A for letters either way round, so this covers PETSCII
           without admitting the high range, which machine code is full of. */
        if (n >= 2 && (c == CR || c == 0x0A || c == 0x09
                       || (c >= 0x20 && c <= 0x7E)))
            ++good;
        ++n;
        if (iec_status() & ST_EOI)
            break;
    }
    iec_close();
    iec_clrchn();

    if (n < 4)
        return 0;                       /* too little to judge on */

    /* Tokenized BASIC: loads at $0801 and its first line link points forward
       past itself. The address alone also matches data that happens to start
       $01,$08, which is why the link is checked too -- the same test the text
       editor uses to decide to show a listing. */
    if (h[0] == 0x01 && h[1] == 0x08
        && (unsigned int)(h[2] | ((unsigned int)h[3] << 8)) > 0x0801)
        return 0;

    /* Binary unless nearly all of it reads as text: machine code has plenty of
       incidental $20-$7E bytes, so a simple majority is not enough. */
    return (unsigned char)((unsigned int)good * 8 < (unsigned int)(n - 2) * 7);
}

void cmd_edit(int argc, char *argv[])
{
    /* No name: a NEW empty document, which is what `edit` has always done and is
       a text document by definition -- there is nothing to sniff, and sniffing
       would cost a pointless drive access. (This is where the file browser goes
       when it is written.) */
    if (argc < 2) {
        bank_dispatch((BANK_EDIT << 5) | 0, argc, argv);
        return;
    }
    if (sniff_binary(argv[1]))
        bank_dispatch((BANK_HEX << 5) | 0, argc, argv);
    else
        bank_dispatch((BANK_EDIT << 5) | 0, argc, argv);
}


/* run - call the most recently loaded program like SYS. It returns here (and
   the shell reprompts) if the program ends in RTS; a program that loops or
   takes over the machine never returns. */
#pragma code-name (push, "CODE2")
/* in src/c_io.s: the autostart stub copied into the tape buffer. */
extern unsigned char run_stub[];
extern unsigned char run_stub_end[];

/* Hand the most-recently-loaded program to a real stock environment by
   swapping the One ROM to the stock ROMs, exactly like the cartridge path:
   plant a CBM80 autostart stub the stock reset jumps to. The stub (run_stub
   in c_io.s) sets up a BASIC program the way stock LOAD does (init-without-NEW
   + LINKPRG) and then, per `mode`, either RUNs it (0) or drops to stock BASIC
   READY. (1) so it can be LISTed / RUN by hand; ML programs JMP through their
   load address. Hardware-only (needs the host-control plugin); on a shell-only
   build / VICE the swap is inert and the JMP through (FFFC) re-enters our
   reset, which re-detects the planted CBM80 -- so this is only meaningful on
   the onerom-stock firmware. Never returns. */
static void launch_stock_program(unsigned char mode)
{
    unsigned char *p = (unsigned char *)0xCF00;     /* run-stub home (RAMTAS-safe) */
    unsigned char *cart = (unsigned char *)0x8000;
    unsigned int i, n;

    TAB_CACHE_OK = 0;               /* the stub lands on the cache's 2nd page */
    *(unsigned char *)0xCFF8 = (unsigned char)(load_start & 0xff);
    *(unsigned char *)0xCFF9 = (unsigned char)(load_start >> 8);
    *(unsigned char *)0xCFFA = (unsigned char)(load_end & 0xff);
    *(unsigned char *)0xCFFB = (unsigned char)(load_end >> 8);
    *(unsigned char *)0xCFFC = mode;                /* 0 RUN, 1 READY., 2 typed */
    *(unsigned char *)0xCFFD = default_device;      /* FA: PEEK(186) for the program */

    n = (unsigned int)(run_stub_end - run_stub);
    for (i = 0; i < n; ++i)
        p[i] = run_stub[i];

    cart[0] = 0x00; cart[1] = 0xCF;     /* cold-start vector -> $CF00 */
    cart[2] = 0x00; cart[3] = 0xCF;     /* warm/NMI vector   -> $CF00 */
    cart[4] = 0xC3; cart[5] = 0xC2;     /* "CBM80" autostart signature */
    cart[6] = 0xCD; cart[7] = 0x38; cart[8] = 0x30;

    rbcp_launch_stock();                /* swap; never returns */
}

void cmd_run(int argc, char *argv[])
{
    /* `run <name>` fast-loads the named PRG (the Epyx path, like `fload`) and
       then runs it. Bare `run` re-runs whatever was loaded last. On the C128
       the stock swap targets flash set 4 (the stock C64 set the firmware
       carries), so this works the same as on the C64. */
    if (argc > 1) {
        /* The fast load is bank entry 3 -- the same code `fload` runs, which is
           why `run <name>` == `fload <name>` then `run`. The bank reports its
           own failures, so we only have to notice and stop. */
        bank_dispatch(3, argc, argv);
        if (DM_STAT != DM_OK)
            return;                     /* already reported: the bank sets
                                           load_start/load_end itself */
    } else if (load_start == 0) {
        puts_raw("nothing loaded");
        chrout(CR);
        return;
    }
    launch_stock_program(0);            /* swap to stock and RUN; never returns */
}
#pragma code-name (pop)

/* sys <addr> - call machine code at <addr> in the CURRENT (Tardis) environment,
   as a subroutine: JSR in, and return to the prompt when it RTSes (via
   run_program in c_io.s). Like BASIC's SYS but WITHOUT the run/stock-ROM swap,
   so it suits routines that use only the documented KERNAL entry points ($FFD2
   CHROUT, $FFE4 GETIN, the file-I/O vectors) or that merely trip an I/O-region
   device -- e.g. a SIDKick pico's config, `sys 54301` / `sys 54333`. A program
   that needs stock KERNAL/BASIC belongs on `run`; one that never RTSes (or
   trashes the stack) takes the shell with it -- reset to recover, exactly like
   SYS. The address is decimal by default, hex with a '$' prefix (the peek/poke
   convention), so `sys 54301` matches the number you'd type in BASIC. */
/* in src/parse_addr.s: decimal by default, hex with a '$' prefix (the C64
   convention, so `sys 54301` matches the number a BASIC user would type and
   `sys $d41d` is the same register). Assembly because cc65 compiled the same
   ~20 lines of C into 251 bytes -- the 16-bit shifts and the x10 -- which made
   it the largest helper in the resident ROM after the stock-swap glue. */
extern unsigned int __fastcall__ parse_addr(const char *s);

void cmd_sys(int argc, char *argv[])
{
    if (argc < 2) {
        usage("sys <addr>");
        return;
    }
    run_program(parse_addr(argv[1]));
}

/* basic - leave the shell for real stock BASIC by swapping the One ROM to the
   stock C64 ROMs so stock KERNAL/BASIC take over (there's no OS underneath, but
   there IS a real C64 one bank-swap away -- and it lands you at BASIC, hence the
   name; `exit` was the old name). Uses the
   host-control plugin's RBCP protocol (see src/rbcp/) to load the stock-ROM
   flash slot into a RAM slot, switch to it, and only then hand off. If a
   program was `load`ed first, it is handed to stock BASIC intact (via the
   run-stub: init-without-NEW + LINKPRG) and the user lands at READY. able to
   LIST / RUN it -- without that, the stock reset's cold start would NEW the
   program away. Calling without a previous `load` is fine -- the swap itself
   is the point; the user gets a fresh stock BASIC (or the stock reset
   autostarts a cartridge). Real use requires the host-control plugin (the
   `make onerom-stock` build); on a shell-only OneROM or in VICE the
   protocol calls are inert and the JMP through (FFFC) just re-enters our
   own shell. Never returns; back to the shell needs a power cycle. In the
   BASIC ROM half (with cmd_font/font_select below) to keep the KERNAL half
   clear of the $FE00 back-channel window -- the bank dispatcher (launch.s
   _bank_call) must live in the static KERNAL half, so it spends the budget
   there and cmd_basic/font move here to make room. */
/* basic [command] - swap to the stock ROMs.
 *
 * With a command, it is typed at the stock prompt and executed: `basic sys 54301`
 * reaches a SIDKick pico's menu, which our own `sys` cannot -- that runs the
 * routine in OUR environment, and anything the device feeds back wants a C64
 * (stock ROM internals, not just the published entry points). The line goes into
 * the keyboard buffer for BASIC's own MAIN to read, exactly as `run` types "RUN".
 *
 * Ten characters including the CR, because that is the keyboard buffer -- and
 * UPPERCASED, because the shell's argv is lowercase ASCII while BASIC wants
 * PETSCII uppercase: `sys` as $73,$79,$73 is three graphics characters to a
 * stock C64, and would be a syntax error.
 */
#define RUN_TLEN (*(unsigned char *)0xCFED)
#define RUN_TEXT ((unsigned char *)0xCFEE)
#define RUN_TMAX 10

void cmd_basic(int argc, char *argv[])
{
    unsigned char n = 0, i, j, c;

    settings_save();                    /* snapshot colors + history before leaving */
    if (argc > 1) {
        for (i = 1; i < (unsigned char)argc && n < RUN_TMAX - 1; ++i) {
            if (i > 1)
                RUN_TEXT[n++] = ' ';
            for (j = 0; argv[i][j] && n < RUN_TMAX - 1; ++j) {
                c = (unsigned char)argv[i][j];
                if (c >= 'a' && c <= 'z')
                    c = (unsigned char)(c - 32);
                RUN_TEXT[n++] = c;
            }
        }
        RUN_TEXT[n++] = 0x0D;
        RUN_TLEN = n;
        launch_stock_program(2);        /* never returns */
    }
    /* With a program loaded, hand it to stock BASIC intact (init-without-NEW +
       LINKPRG) and stop at READY. so it can be LISTed / RUN -- a bare cold swap
       would NEW it away. With nothing loaded, just swap: the user gets a fresh
       stock BASIC (or the stock reset autostarts a cartridge). */
    if (load_start != 0)
        launch_stock_program(1);        /* -> stock BASIC READY., program intact */
    rbcp_launch_stock();                /* never returns */
}

/* font [0|1] - live-switch the served character ROM between two font sets via
   RBCP (src/rbcp/launch.s _font_apply). Font A is loadable ROM set 0 (the boot
   set, shell KERNAL+BASIC+charset, served from RAM slot 0); font B is set 4
   (shell KERNAL+BASIC+swedish). To switch to B we LOAD set 4 into RAM slot 2
   (NOT the served slot 0) then SWITCH to it; to switch back we just SWITCH to
   slot 0 (which still holds font A). RAM slot 1 stays the overlay/stock scratch.
   No arg toggles; `font 0`/`font 1` selects. RBCP-only -- "unavailable" without
   a One ROM. HARDWARE-VALIDATE the slot assumptions (boot serves slot 0, slot 2
   free); the constants below are the single place to adjust them.
   Lives in CODE2 (KERNAL ROM) like the other RBCP commands. */
unsigned char font_apply(void);         /* launch.s; 0 = ok, nonzero = failed */
void settings_save(void);               /* shell.c; persists the font choice */
#define FONT_MB_LOAD    (*(unsigned char *)0x02C8)
#define FONT_MB_FLASH   (*(unsigned char *)0x02C9)
#define FONT_MB_RAM     (*(unsigned char *)0x02CA)
#define FONTA_FLASH_SET 1               /* loadable ROM set: shell + US charset */
#define FONTB_FLASH_SET 5               /* loadable ROM set: shell + swedish */
#define FONTB_RAM_SLOT  2               /* free RAM slot to stage font B into */
#define FONTA_RAM_SLOT  0               /* RAM slot font A is staged into */
#define KBD_LAYOUT      (*(unsigned char *)0x02CB) /* irq.s key-table selector */
static unsigned char font_current;      /* BSS: 0 = font A at boot */

/* Which RAM slot the One ROM is serving the BASE set from. It is NOT always 0:
   a font switch re-serves the base out of a different slot (font B lives in
   FONTB_RAM_SLOT), and the two sets differ only in their char ROM, which is the
   whole trick that makes the switch live-safe.

   bank_restore (src/rbcp/launch.s) reads this to switch BACK to the right slot
   after a bank command. It used to assume slot 0, which silently reverted font
   B to font A on the next command -- with KBD_LAYOUT left on Swedish, so the
   keys still emitted $5B/$5C/$5D but the US charset drew them as "[ ] £"
   instead of "ä ö å". reset.s clears it to 0 at boot. */
#define BASE_RAM_SLOT (*(unsigned char *)0x02CE)

/* Switch to font `target` (0 = A, 1 = B): RBCP charset swap plus the matching
   keyboard table (font B pairs with the Swedish key tables so the relabelled
   keycaps type the right glyphs). Returns 0 on success (or no-op when already
   there), nonzero if the switch is unavailable (no One ROM). Also used by
   settings_load() to re-apply a persisted font at boot. */
unsigned char font_select(unsigned char target)
{
    if (target == font_current)
        return 0;
    if (target) {
        FONT_MB_LOAD = 1;
        FONT_MB_FLASH = FONTB_FLASH_SET;
        FONT_MB_RAM = FONTB_RAM_SLOT;
    } else {
        /* LOAD + SWITCH (not switch-only): under the boot-menu firmware the
           bootloader leaves the machine serving RAM slot 1 and slot 0 holds
           the bootloader set, so "slot 0 still has font A" no longer holds.
           Loading the shell set fresh makes font A correct from any state. */
        FONT_MB_LOAD = 1;
        FONT_MB_FLASH = FONTA_FLASH_SET;
        FONT_MB_RAM = FONTA_RAM_SLOT;
    }
    if (font_apply() != 0)
        return 1;
    font_current = target;
    KBD_LAYOUT = target;
    /* The base is now served from this slot; bank calls must come back to it. */
    BASE_RAM_SLOT = target ? FONTB_RAM_SLOT : FONTA_RAM_SLOT;
    return 0;
}

unsigned char font_get(void)
{
    return font_current;
}

/* cmd_font lives in the default CODE (BASIC ROM half), not CODE2: the C=
   boot-menu launcher (src/rbcp/launch.s) added enough KERNAL-half asm to push
   CODE2 into the reserved $FE00 RBCP back-channel window
   (test_rbcp::test_back_channel_window_is_free_fill). It's a cold command and
   the BASIC half has room; the cross-bank call to font_select (CODE2) is fine
   since both ROM halves are always mapped. */
void cmd_font(int argc, char *argv[])
{
    unsigned char target, prev;

    target = (argc < 2) ? (font_current ^ 1) : (argv[1][0] == '1');
    prev = font_current;
    if (font_select(target) != 0) {
        puts_raw("font switch unavailable");
        chrout(CR);
        return;
    }
    if (font_current != prev)
        settings_save();                /* persist the change (no-op w/o NV) */
    puts_raw("font ");
    chrout('0' + font_current);
    chrout(CR);
}

/* cat / less / cp / mv / rm / save / status / cd - one multi-page "files"
   tardis overlay
   (src/overlays/files.c). The resident side is only these thunks: fill the
   mailbox and run the overlay, so the file-read / paging / copy / rename /
   scratch code lives in the overlay flash, not the 16KB ROM. Mailbox at $02D0:
   [0] command, [1] device, [2] arg1 len + [3..] arg1, [19] arg2 len + [20..]
   arg2. */
/* Absolute scalar accessors: a `FB[2] = n` via a base-pointer macro lets cc65
   reuse a loop-clobbered pointer register, so the length lands in the wrong
   place. Constant addresses compile to plain absolute stores. */
#define FB_CMD (*(unsigned char *)0x02D0)
#define FB_DEV (*(unsigned char *)0x02D1)
#define FB_A1L (*(unsigned char *)0x02D2)
#define FB_A1  ((unsigned char *)0x02D3)        /* 16 chars */
#define FB_A2L (*(unsigned char *)0x02E3)
#define FB_A2  ((unsigned char *)0x02E4)        /* 16 chars */

/* Identify the default device quietly at boot (files bank entry 12): prints
   nothing, swallows a failed bank call, and runs the bus in probe mode. */
void identify_boot_device(void)
{
    bank_try((BANK_FILES << 5) | 12, 0, (char **)0);
}
