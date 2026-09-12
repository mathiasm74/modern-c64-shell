/* picker.c - the interactive color picker (border/bg/text with no value).
 *
 * NOT in the 16K ROM: a standalone overlay fetched into $8800 by run_picker()
 * (src/commands/overlay.c). The color to edit (0 border, 1 bg, 2 text) comes in
 * the mailbox at $02D1. Pure CHROUT/GETIN + direct screen/color RAM, no IEC, so
 * the crt0 only wires k_chrout / k_getin.
 *
 * 16 solid color blocks with an 'o' marker under the selected one, moved
 * left/right with the cursor keys. The choice previews live; RETURN keeps it
 * (the shell's settings_after_command then persists it), STOP reverts.
 *
 * Note the text color previews DIFFERENTLY from the other two, and has to. The
 * border and background are single VIC registers, so writing one recolors the
 * screen at once; $0286 only decides the color of characters drawn FROM NOW ON,
 * so setting it changed nothing on a screen that had already been drawn and the
 * text just stayed white (hardware-reported). Previewing it means repainting
 * color RAM -- but ONLY the text rows (0-4). Repainting all 1000 cells took the
 * swatches with it and they had to be redrawn behind it, which flickered them on
 * every keypress; everything below row 4 is either a swatch or a blank space, so
 * there is nothing down there a repaint could usefully change.
 *
 * The title is drawn in REVERSE, which for the text picker is a second sample of
 * the chosen color -- as the character's background rather than its foreground.
 */

unsigned char __fastcall__ k_chrout(unsigned char c);
unsigned char k_getin(void);

#define CLEAR  0x93
#define CR     0x0D
#define CRSR_L 0x9D
#define CRSR_R 0x1D
#define CRSR_D 0x11             /* down = left, so down/right move without shift */
#define STOP   0x03
#define VIC_BORDER (*(unsigned char *)0xD020)
#define VIC_BG     (*(unsigned char *)0xD021)
#define COLOR_REG  (*(unsigned char *)0x0286)
#define SCR  ((unsigned char *)0x0400)
#define CRAM ((unsigned char *)0xD800)
#define MB_WHICH (*(unsigned char *)0x02D1)
#define PICK_ROW 6
#define PICK_COL 4
#define TEXT_ROWS 5             /* rows 0-4 hold the title and the two hints */

static void puts_raw(const char *s)
{
    while (*s)
        k_chrout(*s++);
}

static void apply_color(unsigned char which, unsigned char v)
{
    unsigned int i;

    if (which == 0) {
        VIC_BORDER = v;
        return;
    }
    if (which == 1) {
        VIC_BG = v;
        return;
    }
    COLOR_REG = v;
    /* ...and show it: recolor the text, and ONLY the text. Straight to the final
       value, never blanked first, so it cannot flash -- and stopping at row 4
       leaves the swatches alone, so they neither change nor need redrawing. */
    for (i = 0; i < TEXT_ROWS * 40; ++i)
        CRAM[i] = v;
}

void picker_main(void)
{
    unsigned char which = MB_WHICH;
    unsigned char sel, orig, i, c;
    const char *title;
    unsigned int base = PICK_ROW * 40 + PICK_COL;
    unsigned int mbase = base + 40;

    orig = (which == 0 ? VIC_BORDER : which == 1 ? VIC_BG : COLOR_REG) & 0x0F;
    sel = orig;

    k_chrout(CLEAR);
    title = (which == 0 ? "border color" : which == 1 ? "background color"
                                                      : "text color");
    puts_raw(title);
    for (i = 0; title[i]; ++i)            /* ...in reverse: an example of it, and
                                             for the text picker a second sample
                                             of the color, as the background */
        SCR[i] |= 0x80;
    k_chrout(CR);
    k_chrout(CR);
    puts_raw("crsr left/right to choose, return to set");
    k_chrout(CR);
    puts_raw("stop to cancel");

    for (i = 0; i < 16; ++i) {            /* the 16 color blocks, two cells wide.
                                             Drawn ONCE: the preview repaint stops
                                             above them, so nothing disturbs them
                                             and redrawing every pass only made
                                             them flicker. */
        SCR[base + i * 2]      = 0xA0;
        SCR[base + i * 2 + 1]  = 0xA0;
        CRAM[base + i * 2]     = i;
        CRAM[base + i * 2 + 1] = i;
    }

    for (;;) {
        apply_color(which, sel);          /* live preview */

        for (i = 0; i < 32; ++i)          /* redraw the marker row */
            SCR[mbase + i] = 0x20;
        SCR[mbase + sel * 2]     = 0x77;  /* two-bar marker (PETSCII 183) under */
        SCR[mbase + sel * 2 + 1] = 0x77;  /* both cells of the 2-wide block */
        CRAM[mbase + sel * 2]     = 0x01; /* white */
        CRAM[mbase + sel * 2 + 1] = 0x01;

        do {
            c = k_getin();
        } while (c == 0);
        if (c == CRSR_L || c == CRSR_D)   /* left or down -> previous color */
            sel = sel ? sel - 1 : 15;
        else if (c == CRSR_R)             /* right -> next color */
            sel = (sel + 1) & 0x0F;
        else if (c == CR)                 /* keep the previewed color */
            break;
        else if (c == STOP) {             /* cancel: revert */
            apply_color(which, orig);
            break;
        }
    }
    k_chrout(CLEAR);                       /* clean up for the shell prompt */
}
