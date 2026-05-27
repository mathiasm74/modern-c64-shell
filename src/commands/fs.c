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

#define CR 0x0D

/* in c_io.s: jump to a loaded program; does not return. */
void run_program(unsigned int addr);

/* Start address of the most recently loaded program, or 0 if none. Lives in
   BSS, so it is zero at boot. */
static unsigned int load_start;

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

    iec_set_fa(8);              /* device 8 */
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

    iec_set_fa(8);
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

    puts_raw("loaded $");
    print_hex16(load_start);
    puts_raw("-$");
    print_hex16((unsigned int)(p - 1));
    chrout(CR);
}

/* run - jump to the most recently loaded program. Does not return on
   success; the program takes over the machine. */
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
