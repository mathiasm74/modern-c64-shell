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

void cmd_border(int argc, char *argv[]) { config_run(8, argc, argv); }
void cmd_bg(int argc, char *argv[])     { config_run(9, argc, argv); }
void cmd_text(int argc, char *argv[])   { config_run(10, argc, argv); }
void cmd_prompt(int argc, char *argv[]) { config_run(11, argc, argv); }
