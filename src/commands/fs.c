/* fs.c - filesystem commands over the IEC serial bus.
 *
 * cmd_ls reads the directory by opening the magic "$" file on the drive and
 * decoding the BASIC-program-shaped listing it returns: a load address, then
 * one "line" per entry (a 2-byte link, a 2-byte line number that doubles as
 * the block count, and PETSCII text ending in NUL), terminated by a $00,$00
 * link. The drive sends filenames and the type as PETSCII text, which our
 * ASCII-consistent CHROUT renders as-is (uppercase names show uppercase).
 */
#include "shell.h"
#include "iec.h"

#define CR    0x0D
#define CLEAR 0x93

/* in c_io.s: jump to a loaded program; does not return. */
void run_program(unsigned int addr);

/* Start address of the most recently loaded program, or 0 if none. Lives in
   BSS, so it is zero at boot. */
static unsigned int load_start;

/* The device ls/load/run talk to; `device <n>` changes it. Initialized (DATA,
   restored on reset), not BSS, so it boots as 8. */
static unsigned char default_device = 8;

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

void cmd_ls(int argc, char *argv[])
{
    unsigned char lo, hi, b;
    (void)argc; (void)argv;

    iec_set_fa(default_device);
    iec_set_sa(0);              /* channel 0 */
    iec_setname("$");           /* the directory */
    iec_open();
    if (iec_status() & ST_NODEV) {
        puts_raw("device not present");
        chrout(CR);
        return;                 /* iec_open already released the bus */
    }
    iec_chkin();                /* turn the drive into the talker */

    iec_getbyte();              /* load address (2 bytes) -- discard */
    iec_getbyte();

    for (;;) {
        lo = iec_getbyte();     /* line link pointer */
        if (iec_status() & ST_EOI)
            break;
        hi = iec_getbyte();
        if (lo == 0 && hi == 0)
            break;              /* $00,$00 link -> end of directory */

        lo = iec_getbyte();     /* line number = block count */
        hi = iec_getbyte();
        print_uint(lo | ((unsigned int)hi << 8));
        chrout(' ');

        for (;;) {              /* the line text, up to its NUL terminator */
            b = iec_getbyte();
            if (b == 0 || (iec_status() & ST_EOI))
                break;
            chrout(b);
        }
        chrout(CR);
        if (iec_status() & ST_EOI)
            break;
    }

    iec_close();
    iec_clrchn();
    if (iec_status() & ST_TIMEOUT) {
        puts_raw("read error");     /* drive present but no disk / no data */
        chrout(CR);
    }
}

/* load <name> - read a PRG into memory at the load address stored in its
   first two bytes, and report the range. The program is not started. */
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
        puts_raw("device not present");
        chrout(CR);
        return;
    }
    iec_chkin();

    lo = iec_getbyte();         /* the file's load address */
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

/* rm <name> - scratch a file: write "S0:<name>" to the drive command channel
   (channel 15). The IEC layer folds the name to uppercase PETSCII to match
   the directory. */
void cmd_rm(int argc, char *argv[])
{
    static char cmd[24];
    unsigned char i, j;

    if (argc < 2) {
        puts_raw("usage: rm <name>");
        chrout(CR);
        return;
    }
    cmd[0] = 's';               /* folded to 'S' on the way out */
    cmd[1] = '0';
    cmd[2] = ':';
    i = 3;
    for (j = 0; argv[1][j] && i < sizeof(cmd) - 1; ++j)
        cmd[i++] = argv[1][j];
    cmd[i] = 0;

    iec_set_fa(default_device);
    iec_setname(cmd);
    iec_command();
    if (iec_status() & ST_NODEV) {
        puts_raw("device not present");
        chrout(CR);
    }
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
        puts_raw("device not present");
        chrout(CR);
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
    unsigned char b;

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
        puts_raw("device not present");
        chrout(CR);
        return;
    }
    iec_chkin();
    for (;;) {
        b = iec_getbyte();
        if (iec_status() & ST_TIMEOUT)
            break;
        chrout(b);
        if (iec_status() & ST_EOI)
            break;
    }
    iec_close();
    iec_clrchn();
    if (iec_status() & ST_TIMEOUT) {
        puts_raw("read error");
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
    unsigned char b, lines = 0;

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
        puts_raw("device not present");
        chrout(CR);
        return;
    }
    iec_chkin();
    for (;;) {
        b = iec_getbyte();
        if (iec_status() & ST_TIMEOUT)
            break;
        chrout(b);
        if (b == CR && ++lines >= 22) {
            puts_raw("-- more --");
            if (wait_key() == 'q')
                break;
            chrout(CLEAR);          /* fresh screen for the next page */
            lines = 0;
        }
        if (iec_status() & ST_EOI)
            break;
    }
    iec_close();
    iec_clrchn();
}

/* device <n> - set the device ls/load/run talk to (default 8). */
void cmd_device(int argc, char *argv[])
{
    if (argc < 2) {
        puts_raw("usage: device <n>");
        chrout(CR);
        return;
    }
    default_device = parse_dec(argv[1]);
    puts_raw("device ");
    print_uint(default_device);
    chrout(CR);
}
