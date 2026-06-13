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

/* Scratch buffer for one directory line's text (dir/ls/pwd run one at a
   time, so they can share it). */
static char dir_buf[42];

/* dir/ls/pwd read the "$" listing either over the Epyx fast path (when the
 * drive is fast-capable) or standard IEC. dir_begin picks the source; dir_line
 * parses one BASIC-directory line from it via the unified dir_getbyte/dir_ended
 * below. Earlier the directory was kept on standard IEC because a fast listing
 * came back garbled, but that turned out to be VIC-II badlines corrupting the
 * timed receive (the dir, generated per-entry, just streams while the screen is
 * busy); the receiver now paces around badlines (see fastload_recv.s), so the
 * dynamic listing comes back clean. (Hold CTRL to pause it -- pause_while_ctrl
 * below; the fast path receives a byte at a time, so it pauses just the same.)
 *
 * Fast source: read the Epyx stream a byte at a time, crossing its [length]
 * [data...] block boundaries transparently -- no whole-directory buffer, so a
 * listing doesn't clobber a loaded program. */
static unsigned char dir_fast;          /* 1 = reading the Epyx block stream  */
static unsigned char fdir_left;         /* bytes left in the current Epyx block */
static unsigned char fdir_eof;          /* fast stream exhausted / timed out   */

static unsigned char dir_getbyte(void)
{
    if (dir_fast) {
        while (fdir_left == 0) {        /* fetch the next block's length byte  */
            if (fdir_eof || epyx_wait_ready() != 0) {
                fdir_eof = 1;
                return 0;
            }
            fdir_left = epyx_recv_byte();
            if (fdir_left == 0) {       /* a 0-length block marks end-of-file  */
                fdir_eof = 1;
                return 0;
            }
        }
        --fdir_left;
        return epyx_recv_byte();
    }
    return iec_getbyte();
}

static unsigned char dir_ended(void)
{
    if (dir_fast)
        return fdir_eof;
    return (iec_status() & (ST_EOI | ST_TIMEOUT)) ? 1 : 0;
}

/* Open the directory of the default device and skip its 2-byte load address.
   Returns 1 if the drive answered, 0 (after reporting it) if no device. */
static unsigned char dir_begin(void)
{
    dir_fast = 0;
    fdir_left = 0;
    fdir_eof = 0;

    /* Try the Epyx fast path first on a capable drive. */
    fastload_set_device(default_device);
    if (fastload_epyx_capable()) {
        fastload_epyx_install();
        if (!(iec_status() & ST_NODEV)) {
            if (fastload_epyx_send_header("$", 1) == 0) {
                dir_fast = 1;
                dir_getbyte();          /* load address (2 bytes) */
                dir_getbyte();
                return 1;
            }
            fastload_epyx_mark_unsupported();
        }
    }

    /* Standard IEC fallback. */
    iec_set_fa(default_device);
    iec_set_sa(0);
    iec_setname("$");
    iec_open();
    if (iec_status() & ST_NODEV) {
        report_no_device(default_device);
        return 0;
    }
    iec_chkin();
    iec_getbyte();              /* load address */
    iec_getbyte();
    return 1;
}

/* Read the next directory line into dir_buf (NUL-terminated) and its block
   count into *blocks. Returns 1 for a line, 0 at the end of the directory. */
static unsigned char dir_line(unsigned int *blocks)
{
    unsigned char lo, hi, b, n;

    lo = dir_getbyte();         /* link pointer */
    if (dir_ended())
        return 0;
    hi = dir_getbyte();
    if (lo == 0 && hi == 0)
        return 0;               /* $00,$00 link -> end of directory */

    lo = dir_getbyte();         /* line number = block count */
    hi = dir_getbyte();
    *blocks = lo | ((unsigned int)hi << 8);

    n = 0;
    for (;;) {
        b = dir_getbyte();
        if (b == 0 || dir_ended())
            break;
        if (n < sizeof(dir_buf) - 1)
            dir_buf[n++] = b;
    }
    dir_buf[n] = 0;
    return 1;
}

static void dir_end(void)
{
    if (dir_fast) {
        /* Drain any remaining Epyx blocks to the end-of-stream marker so the
           bus is left idle for the next command (the parse stops at the
           directory's $00,$00 link, before the Epyx 0-length EOF block). */
        while (!fdir_eof)
            dir_getbyte();
        dir_fast = 0;
        return;
    }
    iec_close();
    iec_clrchn();
    if (iec_status() & ST_TIMEOUT) {
        puts_raw("read error");     /* drive present but no disk / no data */
        chrout(CR);
    }
}

/* dir - the full 1541-style listing: block count, name, type, blocks free. */
/* Hold CTRL to pause a listing (the classic C64 slow-scroll key). The IRQ
   keyboard scan keeps SHFLAG ($028D) current while we spin, and the IEC
   transfer is host-paced, so the drive simply waits between bytes. */
#define SHFLAG_REG (*(volatile unsigned char *)0x028D)
static void pause_while_ctrl(void)
{
    while (SHFLAG_REG & 0x04)
        ;
}

void cmd_dir(int argc, char *argv[])
{
    unsigned int blocks;
    (void)argc; (void)argv;

    if (!dir_begin())
        return;
    while (dir_line(&blocks)) {
        print_uint(blocks);
        chrout(' ');
        puts_raw(dir_buf);
        chrout(CR);
        pause_while_ctrl();
    }
    dir_end();
}

/* The text color for a directory entry of the given type, keyed on the first
   letter of its 3-letter type word; 0 = not a file line (skip it). */
/* ls (and its type matcher) park in the KERNAL ROM: the BASIC ROM is full. */
#pragma code-name (push, "CODE2")
#pragma rodata-name (push, "RODATA2")
static unsigned char type_color(char t)
{
    /* Fold the type letter before matching: a 1541 sends uppercase ASCII
       ('S'), but other drives differ -- Meatloaf can deliver lowercase or
       shifted-PETSCII uppercase ($C1-$DA), and ls was silently hiding
       those files (the line got skipped as "not a file"). */
    if (t >= 'a' && t <= 'z')
        t -= 0x20;
    if ((unsigned char)t >= 0xC1 && (unsigned char)t <= 0xDA)
        t -= 0x80;
    switch (t) {
    case 'P': return 0x0D;      /* PRG - light green */
    case 'S': return 0x03;      /* SEQ - cyan */
    case 'U': return 0x07;      /* USR - yellow */
    case 'R': return 0x0A;      /* REL - light red */
    case 'D': return 0x0C;      /* DEL - grey */
    default:  return 0x00;      /* header / blocks-free: not a file */
    }
}

/* ls - just the file names, colored by type where we know it.
 *
 * Every quoted-name line after the header is a file. The header is always
 * the FIRST line of the listing (dir/pwd rely on that too), so it's
 * skipped positionally -- NOT by whitelisting type tokens: a 1541 only
 * ever says PRG/SEQ/USR/REL/DEL, but Meatloaf synthesizes the type from
 * the filename extension (TXT, D64, DIR, SID, ...), and keying visibility
 * on known types silently hid those files (user report: a saved
 * "test12.txt" appeared in dir but not ls). Unknown types list in the
 * current text color; known ones keep their colors.                     */
void cmd_ls(int argc, char *argv[])
{
    unsigned int blocks;
    unsigned char i, q2, t, color, saved, first;
    (void)argc; (void)argv;

    if (!dir_begin())
        return;
    saved = *TEXT_COLOR;
    first = 1;
    while (dir_line(&blocks)) {
        if (first) {
            first = 0;                  /* the disk-name header line */
            continue;
        }
        for (i = 0; dir_buf[i] && dir_buf[i] != '"'; ++i)
            ;
        if (dir_buf[i] != '"')          /* no quoted name -> blocks-free line */
            continue;
        ++i;                            /* name runs from i to the next quote */
        for (q2 = i; dir_buf[q2] && dir_buf[q2] != '"'; ++q2)
            ;
        if (dir_buf[q2] != '"')
            continue;
        for (t = q2 + 1; dir_buf[t] == ' '; ++t)  /* type follows the quote */
            ;
        if (dir_buf[t] == '*')          /* splat (improperly closed file): */
            ++t;                        /* still a file -- list it         */
        color = type_color(dir_buf[t]);
        *TEXT_COLOR = color ? color : saved;
        while (i < q2)
            chrout(dir_buf[i++]);       /* the name */
        chrout(CR);
        pause_while_ctrl();
    }
    *TEXT_COLOR = saved;                /* restore so the prompt is white */
    dir_end();
}
#pragma rodata-name (pop)
#pragma code-name (pop)

/* pwd - print the current device (number and name, if any) and the disk's
   name (the quoted title in the directory header), e.g. "9 fd: TEST DISK". */
void cmd_pwd(int argc, char *argv[])
{
    unsigned int blocks;
    unsigned char i;
    const char *name;
    (void)argc; (void)argv;

    if (!dir_begin())
        return;
    if (dir_line(&blocks)) {            /* first line is the header */
        print_uint(default_device);
        name = current_device_name();
        if (name[0]) {
            chrout(' ');
            puts_raw(name);
        }
        puts_raw(": ");
        for (i = 0; dir_buf[i] && dir_buf[i] != '"'; ++i)
            ;
        if (dir_buf[i] == '"') {
            ++i;
            while (dir_buf[i] && dir_buf[i] != '"')
                chrout(dir_buf[i++]);
        }
        chrout(CR);
    }
    dir_end();
}

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

void cmd_fload(int argc, char *argv[])
{
    unsigned char namebuf[16];
    unsigned char namelen;
    unsigned int end;

    if (argc < 2) {
        puts_raw("usage: fload <name>");
        chrout(CR);
        return;
    }
    namelen = fold_name(namebuf, argv[1]);

    /* No screen-blanking here: the receiver (_epyx_recv_byte) now pauses each
       byte around VIC-II badlines via the raster, so the display stays visible
       during the load. */
    fastload_set_device(default_device);
    fastload_epyx_install();
    if (iec_status() & ST_NODEV) {
        report_no_device(default_device);
        return;
    }
    if (fastload_epyx_send_header((const char *)namebuf, namelen) != 0) {
        /* the drive never did the Epyx "ready for header" handshake: it isn't
           Epyx-capable (or the protocol isn't enabled on it). */
        fastload_epyx_mark_unsupported();
        puts_raw("fast load not supported");
        chrout(CR);
        return;
    }

    end = fast_receive_prg();
    if (end == 0) {
        puts_raw("fast load failed");
        chrout(CR);
        return;
    }
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
    (void)argc; (void)argv;
    if (load_start == 0) {
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

/* rm <name> - scratch a file via the drive command channel ("S0:<name>"). */
void cmd_rm(int argc, char *argv[])
{
    if (argc < 2) {
        puts_raw("usage: rm <name>");
        chrout(CR);
        return;
    }
    send_command("s0:", argv[1], 0);
}

/* mv <old> <new> - rename a file via the drive command channel
   ("R0:<new>=<old>"). */
void cmd_mv(int argc, char *argv[])
{
    if (argc < 3) {
        puts_raw("usage: mv <old> <new>");
        chrout(CR);
        return;
    }
    send_command("r0:", argv[2], argv[1]);
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

/* cp <src> <dst> - copy a file. Reads all of src into user RAM at $0800, then
   writes it to a new PRG dst. Limited to what fits below the I/O area; large
   files are capped. */
void cmd_cp(int argc, char *argv[])
{
    unsigned char *buf = (unsigned char *)0x0800;
    unsigned int len = 0;
    unsigned int i;
    static char dst[24];
    unsigned char j, k;

    if (argc < 3) {
        puts_raw("usage: cp <src> <dst>");
        chrout(CR);
        return;
    }

    /* read src (channel 0, load semantics: load address then data) */
    iec_set_fa(default_device);
    iec_set_sa(0);
    iec_setname(argv[1]);
    iec_open();
    if (iec_status() & ST_NODEV) {
        report_no_device(default_device);
        return;
    }
    iec_chkin();
    for (;;) {
        if (len >= 0x9000)              /* don't overrun $0800.. into I/O */
            break;
        buf[len++] = iec_getbyte();
        if (iec_status() & (ST_EOI | ST_TIMEOUT))
            break;
    }
    iec_close();
    iec_clrchn();
    if (iec_status() & ST_TIMEOUT) {
        puts_raw("read error");
        chrout(CR);
        return;
    }

    /* build "<dst>,p,w" (folded to uppercase on the way out) */
    k = 0;
    for (j = 0; argv[2][j] && k < 16; ++j)
        dst[k++] = argv[2][j];
    dst[k++] = ',';
    dst[k++] = 'p';
    dst[k++] = ',';
    dst[k++] = 'w';
    dst[k] = 0;

    /* write dst (channel 2, a write data channel) */
    iec_set_sa(2);
    iec_setname(dst);
    iec_open();
    iec_chkout();
    for (i = 0; i < len; ++i) {
        if (i + 1 == len)
            iec_puteoi(buf[i]);     /* last byte with EOI so CLOSE finalizes */
        else
            iec_putbyte(buf[i]);
    }
    iec_unlisten();
    iec_close();
    iec_clrchn();

    puts_raw("copied ");
    print_uint(len);
    puts_raw(" bytes");
    chrout(CR);
}

/* cat <name> - dump a file's bytes to the screen. */
void cmd_cat(int argc, char *argv[])
{
    unsigned char b, last = CR;

    if (argc < 2) {
        puts_raw("usage: cat <name>");
        chrout(CR);
        return;
    }
    iec_set_fa(default_device);
    iec_set_sa(2);                  /* a read data channel */
    iec_setname(argv[1]);
    iec_open();
    if (iec_status() & ST_NODEV) {
        report_no_device(default_device);
        return;
    }
    iec_chkin();
    for (;;) {
        b = iec_getbyte();
        if (iec_status() & ST_TIMEOUT)
            break;
        chrout(b);
        last = b;
        if (iec_status() & ST_EOI)
            break;
    }
    iec_close();
    iec_clrchn();
    if (iec_status() & ST_TIMEOUT) {
        puts_raw("read error");
        chrout(CR);
    } else if (last != CR) {        /* end on a fresh line for the prompt */
        chrout(CR);
    }
}

/* Block until a key is pressed; return it. */
static unsigned char wait_key(void)
{
    unsigned char c;

    do {
        c = getin();
    } while (c == 0);
    return c;
}

/* less <name> - page a file: 22 lines at a time, "-- more --" between pages
   (any key continues, 'q' quits, each page on a fresh screen). */
void cmd_less(int argc, char *argv[])
{
    unsigned char b, lines = 0, last = CR;

    if (argc < 2) {
        puts_raw("usage: less <name>");
        chrout(CR);
        return;
    }
    iec_set_fa(default_device);
    iec_set_sa(2);
    iec_setname(argv[1]);
    iec_open();
    if (iec_status() & ST_NODEV) {
        report_no_device(default_device);
        return;
    }
    iec_chkin();
    for (;;) {
        b = iec_getbyte();
        if (iec_status() & ST_TIMEOUT)
            break;
        chrout(b);
        last = b;
        if (b == CR && ++lines >= 22) {
            puts_raw("-- more --");
            if (wait_key() == 'q')
                break;
            chrout(CLEAR);          /* fresh screen for the next page */
            lines = 0;
            last = CR;
        }
        if (iec_status() & ST_EOI)
            break;
    }
    iec_close();
    iec_clrchn();
    if (last != CR)                 /* end on a fresh line for the prompt */
        chrout(CR);
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
