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

/* Open the directory of the default device and skip its 2-byte load address.
   Returns 1 if the drive answered, 0 (after reporting it) if no device. */
static unsigned char dir_begin(void)
{
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

    lo = iec_getbyte();         /* link pointer */
    if (iec_status() & (ST_EOI | ST_TIMEOUT))
        return 0;
    hi = iec_getbyte();
    if (lo == 0 && hi == 0)
        return 0;               /* $00,$00 link -> end of directory */

    lo = iec_getbyte();         /* line number = block count */
    hi = iec_getbyte();
    *blocks = lo | ((unsigned int)hi << 8);

    n = 0;
    for (;;) {
        b = iec_getbyte();
        if (b == 0 || (iec_status() & (ST_EOI | ST_TIMEOUT)))
            break;
        if (n < sizeof(dir_buf) - 1)
            dir_buf[n++] = b;
    }
    dir_buf[n] = 0;
    return 1;
}

static void dir_end(void)
{
    iec_close();
    iec_clrchn();
    if (iec_status() & ST_TIMEOUT) {
        puts_raw("read error");     /* drive present but no disk / no data */
        chrout(CR);
    }
}

/* dir - the full 1541-style listing: block count, name, type, blocks free. */
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
    }
    dir_end();
}

/* The text color for a directory entry of the given type, keyed on the first
   letter of its 3-letter type word; 0 = not a file line (skip it). */
static unsigned char type_color(char t)
{
    switch (t) {
    case 'P': return 0x0D;      /* PRG - light green */
    case 'S': return 0x03;      /* SEQ - cyan */
    case 'U': return 0x07;      /* USR - yellow */
    case 'R': return 0x0A;      /* REL - light red */
    case 'D': return 0x0C;      /* DEL - grey */
    default:  return 0x00;      /* header / blocks-free: not a file */
    }
}

/* ls - just the file names, each colored by its type. */
void cmd_ls(int argc, char *argv[])
{
    unsigned int blocks;
    unsigned char i, q2, t, color, saved;
    (void)argc; (void)argv;

    if (!dir_begin())
        return;
    saved = *TEXT_COLOR;
    while (dir_line(&blocks)) {
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
        color = type_color(dir_buf[t]);
        if (color == 0)                 /* header line (id/dostype): skip */
            continue;
        *TEXT_COLOR = color;
        while (i < q2)
            chrout(dir_buf[i++]);       /* the name */
        chrout(CR);
    }
    *TEXT_COLOR = saved;                /* restore so the prompt is white */
    dir_end();
}

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
void cmd_load(int argc, char *argv[])
{
    unsigned char lo, hi;
    unsigned char *p;

    if (argc < 2) {
        puts_raw("usage: load <name>");
        chrout(CR);
        return;
    }

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

    puts_raw("loaded $");
    print_hex16(load_start);
    puts_raw("-$");
    print_hex16((unsigned int)(p - 1));
    chrout(CR);
}
#pragma rodata-name (pop)
#pragma code-name (pop)

/* run - call the most recently loaded program like SYS. It returns here (and
   the shell reprompts) if the program ends in RTS; a program that loops or
   takes over the machine never returns. */
void cmd_run(int argc, char *argv[])
{
    (void)argc; (void)argv;

    if (load_start == 0) {
        puts_raw("nothing loaded");
        chrout(CR);
        return;
    }
    run_program(load_start);
}

/* runstock - swap the One ROM to stock C64 ROMs and JMP through (FFFC) so
   stock KERNAL's reset path runs. Uses the host-control plugin's RBCP
   protocol (see src/rbcp/) to load the stock-ROM flash slot into a RAM
   slot, switch to it, and only then hand off. After the swap the user
   lands at stock BASIC's READY. prompt; a program previously loaded into
   RAM via `load` survives the reset, so `RUN` picks it up. Calling without
   a previous `load` is fine -- the swap itself is the point; the user
   gets stock BASIC. Real use requires the host-control plugin (the
   `make onerom-stock` build); on a shell-only OneROM or in VICE the
   protocol calls are inert and the JMP through (FFFC) just re-enters our
   own shell. Never returns; back to the shell needs a power cycle. Lives
   in CODE2 (KERNAL ROM) so its bytes don't push the BASIC ROM over budget. */
#pragma code-name (push, "CODE2")
void cmd_runstock(int argc, char *argv[])
{
    (void)argc; (void)argv;
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
