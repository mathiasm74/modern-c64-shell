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

/* in src/rbcp/launch.s: tardis proof-of-concept. Enters RBCP command-
   response mode, SLOT_PEEKs 64 bytes from RAM slot 0 (the active slot,
   i.e. our own served image) offset 0 into the back-channel window, and
   exits. 0 = ok, 1 = enter failed, 2 = peek failed, 3 = exit failed.   */
unsigned char rbcp_poc_peek(void);

/* tardis: prove the overlay transport (PLAN.md backlog #4). A successful
   peek of our own image's first 64 bytes must reproduce the KERNAL ROM's
   first bytes ($E000..) in the back-channel window at $FE08 -- comparing
   against both halves also tells us the slot image's chip order. Only
   meaningful on One ROM hardware with the host-control plugin; in VICE
   (or on the plain `make onerom` firmware) the handshake times out and
   this reports the stage that failed.                                   */
#pragma code-name (push, "CODE2")
#pragma rodata-name (push, "RODATA2")
void cmd_tardis(int argc, char *argv[])
{
    const unsigned char *win = (const unsigned char *)0xFE08;
    const unsigned char *krn = (const unsigned char *)0xE000;
    const unsigned char *bas = (const unsigned char *)0xA000;
    unsigned char mk = 1, mb = 1;
    unsigned char rc, i;

    (void)argc; (void)argv;
    rc = rbcp_poc_peek();
    if (rc != 0) {
        puts_raw("rbcp error, stage ");
        chrout('0' + rc);
        chrout(CR);
        return;
    }
    puts_raw("window: ");
    for (i = 0; i < 8; ++i) {
        print_hex8(win[i]);
        chrout(' ');
    }
    chrout(CR);
    for (i = 0; i < 64; ++i) {
        if (win[i] != krn[i])
            mk = 0;
        if (win[i] != bas[i])
            mb = 0;
    }
    if (mk)
        puts_raw("matches kernal ($e000)");
    else if (mb)
        puts_raw("matches basic ($a000)");
    else
        puts_raw("matches neither half");
    chrout(CR);
}
#pragma rodata-name (pop)
#pragma code-name (pop)
