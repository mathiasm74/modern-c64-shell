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

/* Parse a small decimal number (the device number). */
static unsigned char parse_dec(const char *s)
{
    unsigned char v = 0;

    while (*s >= '0' && *s <= '9') {
        v = v * 10 + (*s - '0');
        ++s;
    }
    return v;
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

/* Probe whether `dev` is on the bus: open its directory and look for the
   no-device timeout, then leave the bus idle. Returns 1 if it answered. A
   present-but-diskless drive still counts as present (it acknowledges; "no
   disk" only surfaces when something tries to read). Opening "$" is harmless
   and read-only; the open's own bus cleanup (broadcast UNLISTEN/UNTALK on a
   timeout) leaves any *other* present device idle. */
static unsigned char device_present(unsigned char dev)
{
    unsigned char absent;

    iec_set_fa(dev);
    iec_set_sa(0);
    iec_setname("$");
    iec_open();
    absent = iec_status() & ST_NODEV;
    iec_close();                /* release the channel (sends abort if absent) */
    iec_clrchn();
    return absent ? 0 : 1;
}
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

/* runstock - swap the One ROM to stock C64 ROMs so stock KERNAL/BASIC take
   over. Uses the host-control plugin's RBCP protocol (see src/rbcp/) to load
   the stock-ROM flash slot into a RAM slot, switch to it, and only then hand
   off. If a program was `load`ed first, it is handed to stock BASIC intact
   (via the run-stub: init-without-NEW + LINKPRG) and the user lands at READY.
   able to LIST / RUN it -- without that, the stock reset's cold start would
   NEW the program away. Calling without a previous `load` is fine -- the swap
   itself is the point; the user gets a fresh stock BASIC (or the stock reset
   autostarts a cartridge). Real use requires the host-control plugin (the
   `make onerom-stock` build); on a shell-only OneROM or in VICE the
   protocol calls are inert and the JMP through (FFFC) just re-enters our
   own shell. Never returns; back to the shell needs a power cycle. Lives
   in CODE2 (KERNAL ROM) so its bytes don't push the BASIC ROM over budget. */
#pragma code-name (push, "CODE2")
void cmd_runstock(int argc, char *argv[])
{
    (void)argc; (void)argv;
    /* With a program loaded, hand it to stock BASIC intact (init-without-NEW +
       LINKPRG) and stop at READY. so it can be LISTed / RUN -- a bare cold swap
       would NEW it away. With nothing loaded, just swap: the user gets a fresh
       stock BASIC (or the stock reset autostarts a cartridge). */
    if (load_start != 0)
        launch_stock_program(1);        /* -> stock BASIC READY., program intact */
    rbcp_launch_stock();                /* never returns */
}
#pragma code-name (pop)

/* Send "<prefix><arg1>[=<arg2>]" on the default device's command channel.
   Shared by rm ("S0:name"), cd ("CD:path"), and mv ("R0:new=old"). The IEC
   layer folds the name to uppercase PETSCII as it sends. */
static char cmd_buf[40];

static void send_command(const char *prefix, const char *arg1, const char *arg2)
{
    unsigned char i = 0, j;

    while (*prefix && i < sizeof(cmd_buf) - 1)
        cmd_buf[i++] = *prefix++;
    for (j = 0; arg1[j] && i < sizeof(cmd_buf) - 2; ++j)
        cmd_buf[i++] = arg1[j];
    if (arg2 != 0) {
        cmd_buf[i++] = '=';
        for (j = 0; arg2[j] && i < sizeof(cmd_buf) - 1; ++j)
            cmd_buf[i++] = arg2[j];
    }
    cmd_buf[i] = 0;

    iec_set_fa(default_device);
    iec_setname(cmd_buf);
    iec_command();
    if (iec_status() & ST_NODEV)
        report_no_device(default_device);
}

/* cd <path> - change the working path on the drive ("CD:<path>"). A 1541
   answers ?SYNTAX ERROR and stays put; network-side drives like the Meatloaf
   navigate. Whatever the drive does with it shows up on the next dir / pwd.
   Note the IEC layer folds the path to uppercase, so case-sensitive URL
   segments may need a follow-up. */
void cmd_cd(int argc, char *argv[])
{
    if (argc < 2) {
        puts_raw("usage: cd <path>");
        chrout(CR);
        return;
    }
    send_command("cd:", argv[1], 0);
}

/* cat / less / cp / mv / rm - one multi-page "files" tardis overlay
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

static void files_run(unsigned char cmd, const char *a1, const char *a2)
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

/* save <name> [<start> <end>] - write a memory range to disk as a PRG. With no
   range, saves the last-loaded program (load_start..load_end), like stock
   SAVE. <start> becomes the PRG's 2-byte load address so load/fload restore it
   in place; <end> is the inclusive last byte (matching what `load` reports).
   Numbers are decimal or $hex. The write goes through the files overlay (cmd 5,
   reusing its KERNAL-ABI write path); we pass start+count in the A2 mailbox
   bytes via absolute scalars to dodge the cc65 base-pointer store bug.
   In CODE2 (KERNAL ROM) -- the BASIC ROM half is tight. */
#pragma code-name (push, "CODE2")
#pragma rodata-name (push, "RODATA2")
#define SV_START (*(unsigned int *)0x02E4)
#define SV_COUNT (*(unsigned int *)0x02E6)

/* Parse a 16-bit address/value: hex if it starts with '$', else decimal -- the
   same C64 convention as peek/poke (parse_num in mem.c). */
static unsigned int parse_num(const char *s)
{
    unsigned int v = 0;
    unsigned char d;

    if (*s == '$') {
        ++s;
        for (;;) {
            d = *s++;
            if (d >= '0' && d <= '9')
                d -= '0';
            else if (d >= 'a' && d <= 'f')
                d -= 'a' - 10;
            else if (d >= 'A' && d <= 'F')
                d -= 'A' - 10;
            else
                break;
            v = (v << 4) | d;
        }
    } else {
        while (*s >= '0' && *s <= '9')
            v = v * 10 + (*s++ - '0');
    }
    return v;
}

void cmd_save(int argc, char *argv[])
{
    unsigned int start, end;
    unsigned char n;

    if (argc < 2 || argc == 3) {
        puts_raw("usage: save <name> [<start> <end>]");
        chrout(CR);
        return;
    }
    if (argc >= 4) {
        start = parse_num(argv[2]);
        end = parse_num(argv[3]);               /* inclusive last byte */
        if (end < start) {
            puts_raw("end before start");
            chrout(CR);
            return;
        }
        SV_COUNT = end - start + 1;
    } else {
        if (load_start == 0) {
            puts_raw("nothing loaded");
            chrout(CR);
            return;
        }
        start = load_start;
        SV_COUNT = load_end - load_start;       /* load_end is one past last */
    }
    SV_START = start;

    FB_CMD = 5;
    FB_DEV = default_device;
    n = 0;
    while (argv[1][n] && n < 16) { FB_A1[n] = argv[1][n]; ++n; }
    FB_A1L = n;
    run_files_overlay();
}
#pragma rodata-name (pop)
#pragma code-name (pop)

/* status - read and print the drive's command/error channel (15), the classic
   "blinking red light" check: `OPEN 1,8,15: INPUT#1,A,B$,C,D`. After any disk
   op it shows "00, ok,00,00" or an error like "63,file exists,00,00". Opening
   channel 15 with no filename just reads the status; the message ends with a
   CR (sent with EOI), which also drops the prompt onto a fresh line. Resident
   (BASIC ROM) -- it's a quick IEC read used constantly. */
void cmd_status(int argc, char *argv[])
{
    unsigned char b;

    (void)argc; (void)argv;
    iec_set_fa(default_device);
    iec_set_sa(15);                     /* command/error channel */
    iec_setname("");                    /* no command: just read the status */
    iec_open();
    if (iec_status() & ST_NODEV) {
        report_no_device(default_device);
        return;
    }
    iec_chkin();
    for (;;) {
        b = iec_getbyte();
        if (iec_status() & ST_TIMEOUT) {
            puts_raw("read error");
            chrout(CR);
            break;
        }
        chrout(b);                      /* prints the trailing CR on EOI too */
        if (iec_status() & ST_EOI)
            break;
    }
    iec_close();
    iec_clrchn();
}

/* device <n> [name] - set the device ls/load/run talk to (default 8). The bus
   is probed first: if <n> doesn't answer, report it and keep the current
   device (so a typo'd unit number can't silently misdirect later commands). A
   name, if given, is remembered for that device number and reused when
   `device <n>` is later given without one. */
void cmd_device(int argc, char *argv[])
{
    unsigned char dev;
    const char *name;

    if (argc < 2) {
        puts_raw("usage: device <n> [name]");
        chrout(CR);
        return;
    }
    dev = parse_dec(argv[1]);
    if (!device_present(dev)) {         /* don't switch to a unit that isn't there */
        report_no_device(dev);
        return;
    }
    default_device = dev;
    if (argc >= 3 && default_device >= DEV_MIN && default_device <= DEV_MAX) {
        char *slot = device_name[default_device - DEV_MIN];
        unsigned char i;
        for (i = 0; argv[2][i] && i < DEVNAME_MAX; ++i)
            slot[i] = argv[2][i];
        slot[i] = 0;
    }
    puts_raw("device ");
    print_uint(default_device);
    name = current_device_name();
    if (name[0]) {
        chrout(' ');
        puts_raw(name);
    }
    chrout(CR);
}
