/* config.c - appearance: screen colors and the prompt string.
 *
 * Colors are C64 color numbers 0-15. border/bg poke the VIC registers
 * directly; text sets the current text color (COLOR, $0286) that CHROUT
 * writes for new characters. prompt changes the string main() shows; it
 * lives in shell.c, set through set_prompt().
 */
#include "shell.h"
#include "commands/config.h"

#define CR     0x0D
#define VIC_BORDER ((unsigned char *)0xD020)
#define VIC_BG     ((unsigned char *)0xD021)
#define TEXT_COLOR ((unsigned char *)0x0286)   /* KERNAL COLOR */

static unsigned char parse_dec(const char *s)
{
    unsigned char v = 0;

    while (*s >= '0' && *s <= '9') {
        v = v * 10 + (*s - '0');
        ++s;
    }
    return v;
}

void cmd_border(int argc, char *argv[])
{
    if (argc < 2) {
        puts_raw("usage: border <0-15>");
        chrout(CR);
        return;
    }
    *VIC_BORDER = parse_dec(argv[1]) & 0x0F;
}

void cmd_bg(int argc, char *argv[])
{
    if (argc < 2) {
        puts_raw("usage: bg <0-15>");
        chrout(CR);
        return;
    }
    *VIC_BG = parse_dec(argv[1]) & 0x0F;
}

void cmd_text(int argc, char *argv[])
{
    if (argc < 2) {
        puts_raw("usage: text <0-15>");
        chrout(CR);
        return;
    }
    *TEXT_COLOR = parse_dec(argv[1]) & 0x0F;
}

void cmd_prompt(int argc, char *argv[])
{
    set_prompt(argc < 2 ? ">" : argv[1]);
}
