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

void cmd_peek(int argc, char *argv[])
{
    if (argc < 2) {
        puts_raw("usage: peek $addr");
        chrout(CR);
        return;
    }
    chrout('$');
    print_hex8(*(unsigned char *)parse_hex(argv[1]));
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
