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
#include "fastload.h"
#include "commands/overlay.h"     /* overlay_run, for the cat/less thunks */

#define CR    0x0D
#define CLEAR 0x93
#define TEXT_COLOR ((unsigned char *)0x0286)    /* KERNAL current text color */
#define WHITE      0x01

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
static unsigned int load_start;
static unsigned int load_end;   /* one past the last byte loaded (= BASIC VARTAB) */

/* The device ls/load/run talk to; `device <n>` changes it. Initialized (DATA,
   restored on reset), not BSS, so it boots as 8. */
static unsigned char default_device = 8;

/* Optional friendly names for devices 8..15 (index = device - 8); empty means
   none. `device <n> <name>` sets one, `device <n>` alone keeps it. BSS, so
   all start empty. */
#define DEV_MIN     8
#define DEV_MAX     15
#define DEVNAME_MAX 10
static char device_name[DEV_MAX - DEV_MIN + 1][DEVNAME_MAX + 1];

/* The remembered name for the current default device, or "" (none / out of
   the 8..15 range). */
static const char *current_device_name(void)
{
    if (default_device >= DEV_MIN && default_device <= DEV_MAX)
        return device_name[default_device - DEV_MIN];
    return "";
}


/* Print an unsigned int in decimal (block counts are small, but the
   blocks-free line can reach a few hundred). */
static void print_uint(unsigned int n)
{
    char buf[5];
    unsigned char i = 0;

    if (n == 0) {
        chrout('0');
        return;
    }
    while (n) {
        buf[i++] = '0' + (n % 10);
        n /= 10;
    }
    while (i)
        chrout(buf[--i]);
}

static void print_hex_nybble(unsigned char n)
{
    n &= 0x0F;
    chrout(n < 10 ? '0' + n : 'a' + (n - 10));
}

/* Print a 16-bit value as four hex digits. */
static void print_hex16(unsigned int v)
{
    print_hex_nybble(v >> 12);
    print_hex_nybble(v >> 8);
    print_hex_nybble(v >> 4);
    print_hex_nybble(v);
}

/* Report that a device didn't answer on the bus, naming the unit. */
static void report_no_device(unsigned char dev)
{
    puts_raw("device ");
    print_uint(dev);
    puts_raw(" not present");
    chrout(CR);
}

/* (device's bus probe moved into the files overlay -- it uses the KERNAL OPEN
   shim there; see do_device / device_present_ov in src/overlays/files.c.) */
/* dir / ls / pwd -- the "dir" tardis overlay (src/overlays/dir.c). These need
   the lower-level IEC bus and the badline-paced Epyx receiver (not KERNAL
   entry points), so the overlay reaches them through the $FF80 services table
   (src/svc.s); the resident side is just these thunks, which pass the device
   and its remembered name in the mailbox at $02D0. */
#define DB_CMD  (*(unsigned char *)0x02D0)       /* 0 dir, 1 ls, 2 pwd */
#define DB_DEV  (*(unsigned char *)0x02D1)
#define DB_NLEN (*(unsigned char *)0x02D2)
#define DB_NAME ((unsigned char *)0x02D3)

static void dir_run(unsigned char cmd)
{
    const char *name;
    unsigned char n = 0;

    DB_CMD = cmd;
    DB_DEV = default_device;
    name = current_device_name();
    while (name[n] && n < 16) {
        DB_NAME[n] = name[n];
        ++n;
    }
    DB_NLEN = n;
    run_dir_overlay();
}

void cmd_dir(int argc, char *argv[]) { (void)argc; (void)argv; dir_run(0); }
void cmd_ls(int argc, char *argv[])  { (void)argc; (void)argv; dir_run(1); }
void cmd_pwd(int argc, char *argv[]) { (void)argc; (void)argv; dir_run(2); }


/* load <name> - read a PRG into memory at the load address stored in its
   first two bytes, and report the range. The program is not started. Lives in
   CODE2/RODATA2 (KERNAL ROM) so its code and strings don't push the smaller
   BASIC ROM over budget. */
#pragma code-name (push, "CODE2")
#pragma rodata-name (push, "RODATA2")
static unsigned char fold_name(unsigned char *buf, const char *src);
static unsigned int fast_receive_prg(void);

void cmd_load(int argc, char *argv[])
{
    unsigned char lo, hi;
    unsigned char *p;

    if (argc < 2) {
        puts_raw("usage: load <name>");
        chrout(CR);
        return;
    }

    /* Standard IEC load: per-byte handshaked, so it is bit-perfect. The Epyx
       fast path is split out into `fload` -- its timed 2-bit receiver is only
       reliable on some drives/links, and on the user's Meatloaf it jitters
       bits and scatters corruption through the file (bogus BASIC line numbers,
       mangled tokens), which a per-byte program then trips over. `load` stays
       the safe, always-correct default, so `run` builds on a clean program. */

    iec_set_fa(default_device);
    iec_set_sa(0);              /* channel 0: a program load */
    iec_setname(argv[1]);
    iec_open();
    if (iec_status() & ST_NODEV) {
        report_no_device(default_device);
        return;
    }
    iec_chkin();

    lo = iec_getbyte();         /* the file's load address */
    /* An immediate EOI with no timeout means the drive opened the channel but
       streamed back no data: the file does not exist. (A genuine read fault --
       no disk, etc. -- sets the timeout bit instead and is reported as "read
       error" below.) Without this check a missing file reads as load address
       $0000 and prints a bogus "loaded $0000-$0000". */
    if ((iec_status() & ST_EOI) && !(iec_status() & ST_TIMEOUT)) {
        iec_close();
        iec_clrchn();
        puts_raw("file not found");
        chrout(CR);
        return;
    }
    hi = iec_getbyte();
    p = (unsigned char *)(lo | ((unsigned int)hi << 8));
    load_start = (unsigned int)p;

    for (;;) {                  /* the last byte arrives with EOI set */
        *p++ = iec_getbyte();
        if (iec_status() & ST_EOI)
            break;
    }

    iec_close();
    iec_clrchn();

    if (iec_status() & ST_TIMEOUT) {
        puts_raw("read error");     /* no disk / file not found / no data */
        chrout(CR);
        return;
    }

    load_end = (unsigned int)p;

    puts_raw("loaded $");
    print_hex16(load_start);
    puts_raw("-$");
    print_hex16((unsigned int)(p - 1));
    chrout(CR);
}
#pragma rodata-name (pop)
#pragma code-name (pop)

/* fload <name> - experimental Epyx fast load (Phase 7). Installs the Epyx
   handshake, requests the file, and receives it over the timed 2-bit protocol;
   leaves it in RAM at its PRG load address (so `run` works afterwards). Kept
   SEPARATE from `load` during bring-up: M-E $01A9 on a drive that isn't Epyx-
   aware would run our fingerprint filler as drive code, so only point this at a
   Meatloaf (or other Epyx-emulating drive). Uses device 8 (the fast loader's
   fixed FA). The 2-bit receive timing still needs hardware calibration -- see
   the PAD note in src/fastload_recv.s; until then this may return garbage.
   Lives in CODE2/RODATA2 (KERNAL ROM). */
#pragma code-name (push, "CODE2")
#pragma rodata-name (push, "RODATA2")
/* Fold a filename to uppercase PETSCII (CBM convention) into buf[16];
   returns the length. */
static unsigned char fold_name(unsigned char *buf, const char *src)
{
    unsigned char n = 0, i;
    char c;

    for (i = 0; src[i] != 0 && n < 16; ++i) {
        c = src[i];
        if (c >= 'a' && c <= 'z')
            c = (char)(c - 32);
        buf[n++] = (unsigned char)c;
    }
    return n;
}

/* Receive a PRG over the Epyx stream into its embedded load address, in
   [length][data...] blocks until a zero-length block. Sets load_start and
   returns the last written address, or 0 if fewer than 3 bytes arrived
   (missing file / broken stream). Caller already sent install + header. */
static unsigned int fast_receive_prg(void)
{
    unsigned char i, n, b;
    unsigned int count = 0;
    unsigned char *dst = (unsigned char *)0x0800;
    unsigned char lo = 0, hi = 0;

    for (;;) {
        if (epyx_wait_ready() != 0)         /* drive never signalled a block  */
            break;
        n = epyx_recv_byte();               /* block length; 0 = end of file  */
        if (n == 0)
            break;
        for (i = 0; i < n; ++i) {
            b = epyx_recv_byte();
            if (count == 0)
                lo = b;
            else if (count == 1) {
                hi = b;
                dst = (unsigned char *)(lo | ((unsigned int)hi << 8));
            } else
                *dst++ = b;
            ++count;
        }
    }
    if (count < 3)                          /* nothing (or only an address)  */
        return 0;
    load_start = (unsigned int)(lo | ((unsigned int)hi << 8));
    load_end = (unsigned int)dst;
    return (unsigned int)(dst - 1);
}

/* Fast-load `name` over the Epyx path into RAM at the PRG's embedded load
   address; sets load_start/load_end. Returns the last written address (the
   value `floaded`/`run` report), or 0 on any failure -- which it has already
   reported (no device / not Epyx-capable / broken stream). Shared by `fload`
   and `run <name>`.

   No screen-blanking: the receiver (_epyx_recv_byte) paces each byte around
   VIC-II badlines via the raster, so the display stays visible during the
   load. */
static unsigned int fload_program(const char *name)
{
    unsigned char namebuf[16];
    unsigned char namelen;

    namelen = fold_name(namebuf, name);

    fastload_set_device(default_device);
    fastload_epyx_install();
    if (iec_status() & ST_NODEV) {
        report_no_device(default_device);
        return 0;
    }
    if (fastload_epyx_send_header((const char *)namebuf, namelen) != 0) {
        /* the drive never did the Epyx "ready for header" handshake: it isn't
           Epyx-capable (or the protocol isn't enabled on it). */
        fastload_epyx_mark_unsupported();
        puts_raw("fast load not supported");
        chrout(CR);
        return 0;
    }
    if (fast_receive_prg() == 0) {
        puts_raw("fast load failed");
        chrout(CR);
        return 0;
    }
    return load_end - 1;
}

void cmd_fload(int argc, char *argv[])
{
    unsigned int end;

    if (argc < 2) {
        puts_raw("usage: fload <name>");
        chrout(CR);
        return;
    }
    end = fload_program(argv[1]);
    if (end == 0)
        return;                 /* fload_program already reported the failure */
    puts_raw("floaded $");
    print_hex16(load_start);
    puts_raw("-$");
    print_hex16(end);
    chrout(CR);
}
#pragma rodata-name (pop)
#pragma code-name (pop)

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

    *(unsigned char *)0xCFF8 = (unsigned char)(load_start & 0xff);
    *(unsigned char *)0xCFF9 = (unsigned char)(load_start >> 8);
    *(unsigned char *)0xCFFA = (unsigned char)(load_end & 0xff);
    *(unsigned char *)0xCFFB = (unsigned char)(load_end >> 8);
    *(unsigned char *)0xCFFC = mode;                /* 0 = RUN, 1 = READY. */
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
       then runs it. Bare `run` re-runs whatever was loaded last. */
    if (argc > 1) {
        if (fload_program(argv[1]) == 0)
            return;                     /* load failed: already reported */
    } else if (load_start == 0) {
        puts_raw("nothing loaded");
        chrout(CR);
        return;
    }
    launch_stock_program(0);            /* swap to stock and RUN; never returns */
}
#pragma code-name (pop)

/* exit - leave the shell by swapping the One ROM to stock C64 ROMs so stock
   KERNAL/BASIC take over (the closest thing to "exit" we have: there's no OS
   underneath, but there IS a real C64 one bank-swap away). Uses the
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
   own shell. Never returns; back to the shell needs a power cycle. Lives
   in CODE2 (KERNAL ROM) so its bytes don't push the BASIC ROM over budget. */
#pragma code-name (push, "CODE2")
void cmd_exit(int argc, char *argv[])
{
    (void)argc; (void)argv;
    settings_save();                    /* snapshot colors + history before leaving */
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
#define FONTB_FLASH_SET 4               /* loadable ROM set: shell + swedish */
#define FONTB_RAM_SLOT  2               /* free RAM slot to stage font B into */
#define FONTA_RAM_SLOT  0               /* the boot-served slot (font A) */
#define KBD_LAYOUT      (*(unsigned char *)0x02CB) /* irq.s key-table selector */
static unsigned char font_current;      /* BSS: 0 = font A at boot */

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
        FONT_MB_LOAD = 0;
        FONT_MB_RAM = FONTA_RAM_SLOT;
    }
    if (font_apply() != 0)
        return 1;
    font_current = target;
    KBD_LAYOUT = target;
    return 0;
}

unsigned char font_get(void)
{
    return font_current;
}

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
#pragma code-name (pop)

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

void files_run(unsigned char cmd, const char *a1, const char *a2)
{
    unsigned char n;

    FB_CMD = cmd;
    FB_DEV = default_device;
    n = 0;
    if (a1)
        while (a1[n] && n < 16) { FB_A1[n] = a1[n]; ++n; }
    FB_A1L = n;
    n = 0;
    if (a2)
        while (a2[n] && n < 16) { FB_A2[n] = a2[n]; ++n; }
    FB_A2L = n;
    run_files_overlay();
}

void cmd_cat(int argc, char *argv[])
{
    if (argc < 2) { puts_raw("usage: cat <name>"); chrout(CR); return; }
    files_run(0, argv[1], 0);
}

void cmd_less(int argc, char *argv[])
{
    if (argc < 2) { puts_raw("usage: less <name>"); chrout(CR); return; }
    files_run(1, argv[1], 0);
}

void cmd_cp(int argc, char *argv[])
{
    if (argc < 3) { puts_raw("usage: cp <src> <dst>"); chrout(CR); return; }
    files_run(2, argv[1], argv[2]);
}

void cmd_mv(int argc, char *argv[])
{
    if (argc < 3) { puts_raw("usage: mv <old> <new>"); chrout(CR); return; }
    files_run(3, argv[1], argv[2]);     /* overlay builds r0:<new>=<old> */
}

void cmd_rm(int argc, char *argv[])
{
    if (argc < 2) { puts_raw("usage: rm <name>"); chrout(CR); return; }
    files_run(4, argv[1], 0);
}

/* cd <path> - change the working path on the drive. The files overlay (cmd 7)
   sends "CD:<path>" via its command_channel and reports a failure as
   "cd: <message>" (a 1541 has no CD and answers SYNTAX ERROR; a Meatloaf
   navigates and only errors on a missing path); success is silent. Paths can
   exceed the 16-char mailbox args (Meatloaf URLs), so the thunk prebuilds the
   whole "cd:<path>" command into a 40-byte scratch at $0340 (free tape-buffer
   RAM) and passes only its length in the mailbox. */
#define CD_CMD ((unsigned char *)0x0340)
void cmd_cd(int argc, char *argv[])
{
    unsigned char i = 0, j;

    if (argc < 2) { puts_raw("usage: cd <path>"); chrout(CR); return; }
    CD_CMD[i++] = 'c'; CD_CMD[i++] = 'd'; CD_CMD[i++] = ':';
    for (j = 0; argv[1][j] && i < 39; ++j)
        CD_CMD[i++] = argv[1][j];
    FB_CMD = 7;
    FB_DEV = default_device;
    FB_A1L = i;                         /* prebuilt-command length (cmd at $0340) */
    run_files_overlay();
}

/* status - read and print the drive's command/error channel (15), the classic
   "blinking red light" check (`OPEN 1,8,15: INPUT#1,A,B$,C,D`). The read +
   reformatting lives in the files overlay (cmd 6, status_read): buffering and
   the comma-field parse cost too much resident ROM. Thin thunk only. */
void cmd_status(int argc, char *argv[])
{
    (void)argc; (void)argv;
    files_run(6, 0, 0);
}

/* device <n> [name] - set the device ls/load/run talk to (default 8). The bus
   is probed first: if <n> doesn't answer, report it and keep the current
   device (so a typo'd unit number can't silently misdirect later commands). A
   name, if given, is remembered for that device number and reused when
   `device <n>` is later given without one. */
void cmd_device(int argc, char *argv[])
{
    /* The parse/probe/report is in the files overlay (cmd 16). default_device
       and device_name stay resident (read everywhere), so pass their addresses
       in the mailbox for the overlay to update in place. */
    *(unsigned char **)0x02F4 = &default_device;
    *(char **)0x02F6 = &device_name[0][0];
    files_run(16, argc > 1 ? argv[1] : 0, argc >= 3 ? argv[2] : 0);
}
