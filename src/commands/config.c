/* config.c - appearance commands (border / bg / text / prompt).
 *
 * These are thin resident thunks: the bodies live in the files overlay
 * (src/overlays/files.c, cmds 8-11), so the parse + register pokes + the
 * prompt-set (via the svc_set_prompt service) cost overlay flash, not the
 * 16KB ROM. The thunk just drops the command id and the argument string into
 * the shared mailbox at $02D0 and runs the overlay.
 */
#include "shell.h"
#include "commands/config.h"
#include "commands/overlay.h"

/* Mailbox (shared with the other files-overlay thunks). Absolute scalars: a
   base-pointer macro after the copy loop would let cc65 misland the length. */
#define FB_CMD (*(unsigned char *)0x02D0)
#define FB_A1L (*(unsigned char *)0x02D2)
#define FB_A1  ((unsigned char *)0x02D3)        /* up to 15 chars */

static void config_run(unsigned char cmd, int argc, char *argv[])
{
    unsigned char n = 0;

    FB_CMD = cmd;
    if (argc > 1)
        while (argv[1][n] && n < 15) { FB_A1[n] = argv[1][n]; ++n; }
    FB_A1L = n;
    run_files_overlay();
}

/* --- interactive color picker (border/bg/text with no value) ----------------
 * 16 solid color blocks with an 'o' under the selected one, moved left/right
 * with the cursor keys. The choice previews live; RETURN keeps it (the shell's
 * settings_after_command then persists it), STOP cancels back to the original.
 * Resident (not in the files overlay, which is full); draws blocks straight to
 * screen/color RAM and reads keys through the same getin() readline uses. */
#define CLEAR  0x93
#define CR     0x0D
#define CRSR_L 0x9D
#define CRSR_R 0x1D
#define STOP   0x03
#define VIC_BORDER (*(unsigned char *)0xD020)
#define VIC_BG     (*(unsigned char *)0xD021)
#define COLOR_REG  (*(unsigned char *)0x0286)
#define SCR  ((unsigned char *)0x0400)
#define CRAM ((unsigned char *)0xD800)
#define PICK_ROW 6
#define PICK_COL 4

static void apply_color(unsigned char which, unsigned char v)
{
    if (which == 0)
        VIC_BORDER = v;
    else if (which == 1)
        VIC_BG = v;
    else
        COLOR_REG = v;
}

static void color_picker(unsigned char which)
{
    unsigned char sel, orig, i, c;
    unsigned int base = PICK_ROW * 40 + PICK_COL;
    unsigned int mbase = base + 40;

    orig = (which == 0 ? VIC_BORDER : which == 1 ? VIC_BG : COLOR_REG) & 0x0F;
    sel = orig;

    chrout(CLEAR);
    puts_raw(which == 0 ? "border color" : which == 1 ? "background color"
                                                      : "text color");
    chrout(CR);
    chrout(CR);
    puts_raw("crsr left/right to choose, return to set");
    chrout(CR);
    puts_raw("stop to cancel");

    for (i = 0; i < 16; ++i) {           /* the 16 color blocks, two cells wide */
        SCR[base + i * 2]      = 0xA0;
        SCR[base + i * 2 + 1]  = 0xA0;
        CRAM[base + i * 2]     = i;
        CRAM[base + i * 2 + 1] = i;
    }

    for (;;) {
        for (i = 0; i < 32; ++i)         /* redraw the marker row */
            SCR[mbase + i] = 0x20;
        SCR[mbase + sel * 2] = 0x0F;     /* 'o' under the selected block */
        CRAM[mbase + sel * 2] = 0x01;    /* white */
        apply_color(which, sel);         /* live preview */

        do {
            c = getin();
        } while (c == 0);
        if (c == CRSR_L)
            sel = sel ? sel - 1 : 15;
        else if (c == CRSR_R)
            sel = (sel + 1) & 0x0F;
        else if (c == CR)                /* keep the previewed color */
            break;
        else if (c == STOP) {            /* cancel: revert */
            apply_color(which, orig);
            break;
        }
    }
    chrout(CLEAR);                        /* clean up for the shell prompt */
}

void cmd_border(int argc, char *argv[])
{
    if (argc < 2) color_picker(0); else config_run(8, argc, argv);
}
void cmd_bg(int argc, char *argv[])
{
    if (argc < 2) color_picker(1); else config_run(9, argc, argv);
}
void cmd_text(int argc, char *argv[])
{
    if (argc < 2) color_picker(2); else config_run(10, argc, argv);
}
void cmd_prompt(int argc, char *argv[]) { config_run(11, argc, argv); }
