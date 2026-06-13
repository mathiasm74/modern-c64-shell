/* builtins.c - the trivial built-in commands.
 *
 * The shell boots in the lowercase/text charset with an ASCII-consistent
 * encoding, so string literals here are plain ASCII: lowercase prose with
 * proper capitalization for headers and proper nouns. See shell.c for the
 * dispatch table that wires these up.
 */
#include "shell.h"
#include "commands/builtins.h"

#define CR    0x0D             /* RETURN / newline */
#define CLEAR 0x93             /* CHROUT clear-screen control code */

/* in c_io.s: reboot through the reset vector; does not return. */
void soft_reset(void);

/* List every registered command, read straight from the dispatch table (which
   shell.c keeps sorted alphabetically) so the columns read top-to-bottom,
   left-to-right. Three 12-wide columns indented 2 spaces fits in 40: 2 + 3*12
   = 38, leaving a 2-column right margin. The function lives in CODE2 (KERNAL
   ROM) so its bytes don't squeeze the smaller BASIC ROM. */
#define HELP_INDENT  2
#define HELP_COLS    3
#define HELP_COL_W  12

#pragma code-name (push, "CODE2")
void cmd_help(int argc, char *argv[])
{
    unsigned char rows, row, col, i, n;
    const char *name;
    (void)argc; (void)argv;

    rows = (shell_command_count + HELP_COLS - 1) / HELP_COLS;
    puts_raw("Commands:");
    chrout(CR);
    for (row = 0; row < rows; ++row) {
        for (n = 0; n < HELP_INDENT; ++n)
            chrout(' ');
        for (col = 0; col < HELP_COLS; ++col) {
            i = col * rows + row;
            if (i >= shell_command_count)
                break;
            name = shell_commands[i].name;
            n = 0;
            while (name[n]) {
                chrout(name[n]);
                ++n;
            }
            while (n < HELP_COL_W) {
                chrout(' ');
                ++n;
            }
        }
        chrout(CR);
    }
}

#pragma code-name (pop)

void cmd_clear(int argc, char *argv[])
{
    (void)argc; (void)argv;
    chrout(CLEAR);
}

/* Print the arguments separated by single spaces, then a newline -- so
   `echo a   b` prints "a b": the parser has already collapsed the run. */
void cmd_echo(int argc, char *argv[])
{
    int i;
    for (i = 1; i < argc; ++i) {
        if (i > 1)
            chrout(' ');
        puts_raw(argv[i]);
    }
    chrout(CR);
}

/* ver and exit park their code + strings in the KERNAL ROM (CODE2/RODATA2):
   the BASIC ROM is full, and these are small and cold. */
#pragma code-name (push, "CODE2")
#pragma rodata-name (push, "RODATA2")
void cmd_ver(int argc, char *argv[])
{
    (void)argc; (void)argv;
    /* Kept in step with the boot banner in reset.s. */
    puts_raw("C64 Shell ROM v0.24");
    chrout(CR);
}

void cmd_exit(int argc, char *argv[])
{
    (void)argc; (void)argv;
    /* No OS underneath and no BASIC to fall back to; say so plainly. */
    puts_raw("Nothing to exit to");
    chrout(CR);
}
#pragma rodata-name (pop)
#pragma code-name (pop)

void cmd_reset(int argc, char *argv[])
{
    (void)argc; (void)argv;
    soft_reset();               /* reboot the shell; does not return */
}
