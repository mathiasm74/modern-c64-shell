/* builtins.c - the trivial built-in commands.
 *
 * The shell boots in the lowercase/text charset with an ASCII-consistent
 * encoding, so string literals here are plain ASCII: lowercase prose with
 * proper capitalization for headers and proper nouns. See shell.c for the
 * dispatch table that wires these up.
 */
#include "shell.h"
#include "commands/builtins.h"
#include "commands/overlay.h"     /* run_files_overlay (help thunk) */

#define CR    0x0D             /* RETURN / newline */
#define CLEAR 0x93             /* CHROUT clear-screen control code */

/* in c_io.s: reboot through the reset vector; does not return. */
void soft_reset(void);

/* List every registered command. The 3-column column-major formatting is in
   the files overlay (cmd 15); this thunk just hands it the dispatch table's
   base and entry count (the overlay walks the const struct command[]). */
void cmd_help(int argc, char *argv[])
{
    (void)argc; (void)argv;
    *(unsigned char *)0x02D0 = 15;                              /* FB_CMD */
    *(unsigned int *)0x02E4 = (unsigned int)&shell_commands[0]; /* table base */
    *(unsigned char *)0x02E6 = shell_command_count;             /* entry count */
    run_files_overlay();
}

void cmd_clear(int argc, char *argv[])
{
    (void)argc; (void)argv;
    chrout(CLEAR);
}

/* ver parks its code + string in the KERNAL ROM (CODE2/RODATA2): the BASIC ROM
   is full, and it's small and cold. */
#pragma code-name (push, "CODE2")
#pragma rodata-name (push, "RODATA2")
void cmd_ver(int argc, char *argv[])
{
    (void)argc; (void)argv;
    /* Brand + version; kept in step with the boot banner's version (reset.s). */
    puts_raw("Tardis DOS v0.1.81");
    chrout(CR);
}
#pragma rodata-name (pop)
#pragma code-name (pop)

void cmd_reset(int argc, char *argv[])
{
    (void)argc; (void)argv;
    settings_save();            /* checkpoint history first (no-op w/o NV) */
    soft_reset();               /* reboot the shell; does not return */
}
