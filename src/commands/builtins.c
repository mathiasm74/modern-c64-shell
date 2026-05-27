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

/* List every registered command, read straight from the dispatch table so
   there is no separate list to keep in sync as commands are added. */
void cmd_help(int argc, char *argv[])
{
    unsigned char i;
    (void)argc; (void)argv;

    puts_raw("Commands:");
    chrout(CR);
    for (i = 0; i < shell_command_count; ++i) {
        puts_raw("  ");
        puts_raw(shell_commands[i].name);
        chrout(CR);
    }
}

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

void cmd_ver(int argc, char *argv[])
{
    (void)argc; (void)argv;
    /* Kept in step with the boot banner in reset.s. */
    puts_raw("C64 Shell ROM v0.1");
    chrout(CR);
}

void cmd_exit(int argc, char *argv[])
{
    (void)argc; (void)argv;
    /* No OS underneath and no BASIC to fall back to; say so plainly. */
    puts_raw("Nothing to exit to");
    chrout(CR);
}

void cmd_reset(int argc, char *argv[])
{
    (void)argc; (void)argv;
    soft_reset();               /* reboot the shell; does not return */
}
