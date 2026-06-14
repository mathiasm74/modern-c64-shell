/* mem.c - direct memory inspection: peek and poke.
 *
 * Numbers are DECIMAL by default and hex when prefixed with '$' -- the C64
 * convention. So `poke 53280 0` (the BASIC address everyone has memorized)
 * works, and `poke $d020 0` is the same register in hex. These read and write
 * the live machine, so they double as a quick way to poke I/O registers.
 */
#include "shell.h"
#include "commands/mem.h"

#define CR 0x0D

/* Parse a number: hex if it starts with '$', else decimal. Stops at the first
   character that isn't a digit of the chosen base. No range checking -- the
   result wraps at 16 bits. Bare = decimal matches stock BASIC (POKE 53280,0);
   '$' marks hex (POKE $D020) -- so a bare hex-looking value like "53280" is
   read as the decimal the user meant, not silently as $53280. */
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
        for (;;) {
            d = *s++;
            if (d < '0' || d > '9')
                break;
            v = v * 10 + (d - '0');
        }
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
        puts_raw("usage: peek <addr> [count] ($=hex)");
        chrout(CR);
        return;
    }
    addr = parse_num(argv[1]);

    /* peek <addr>         -> one byte
       peek <addr> <count> -> hexdump `count` bytes, 8 per row with an address
                              label, so you can read a loaded program's bytes. */
    if (argc < 3) {
        chrout('$');
        print_hex8(*(unsigned char *)addr);
        chrout(CR);
        return;
    }
    count = parse_num(argv[2]);
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
        puts_raw("usage: poke <addr> <val> ($=hex)");
        chrout(CR);
        return;
    }
    *(unsigned char *)parse_num(argv[1]) = (unsigned char)parse_num(argv[2]);
}

