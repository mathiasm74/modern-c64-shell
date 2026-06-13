/* mem.c - direct memory inspection: peek and poke.
 *
 * Addresses and values are hex, with an optional leading '$' (so `peek $d020`
 * and `peek d020` are the same). These read and write the live machine, so
 * they double as a quick way to poke I/O registers.
 */
#include "shell.h"
#include "commands/mem.h"

#define CR 0x0D

/* Parse a hex number, skipping a leading '$'; stops at the first non-hex
   digit. No range checking -- the result wraps at 16 bits. */
static unsigned int parse_hex(const char *s)
{
    unsigned int v = 0;
    unsigned char d;

    if (*s == '$')
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
    return v;
}

static void print_hex_nybble(unsigned char n)
{
    n &= 0x0F;
    chrout(n < 10 ? '0' + n : 'a' + (n - 10));
}

static void print_hex8(unsigned char b)
{
    print_hex_nybble(b >> 4);
    print_hex_nybble(b);
}

static void print_hex16(unsigned int v)
{
    print_hex8((unsigned char)(v >> 8));
    print_hex8((unsigned char)(v & 0xff));
}

void cmd_peek(int argc, char *argv[])
{
    unsigned int addr, count, i;
    unsigned char c, col;

    if (argc < 2) {
        puts_raw("usage: peek $addr [count]");
        chrout(CR);
        return;
    }
    addr = parse_hex(argv[1]);

    /* peek $addr        -> one byte (back-compatible)
       peek $addr $count -> hexdump `count` bytes, 8 per row with an address
                            label, so you can read a loaded program's bytes. */
    if (argc < 3) {
        chrout('$');
        print_hex8(*(unsigned char *)addr);
        chrout(CR);
        return;
    }
    count = parse_hex(argv[2]);
    if (count == 0)
        count = 1;
    col = 0;
    for (i = 0; i < count; ++i) {
        if (col == 0) {
            chrout('$');
            print_hex16(addr + i);
            chrout(':');
        }
        chrout(' ');
        c = *(unsigned char *)(addr + i);
        print_hex8(c);
        if (++col == 8) {
            chrout(CR);
            col = 0;
        }
    }
    if (col != 0)
        chrout(CR);
}

void cmd_poke(int argc, char *argv[])
{
    if (argc < 3) {
        puts_raw("usage: poke $addr $val");
        chrout(CR);
        return;
    }
    *(unsigned char *)parse_hex(argv[1]) = (unsigned char)parse_hex(argv[2]);
}

