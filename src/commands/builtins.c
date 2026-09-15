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

/* (help is a FILES BANK command now -- a dispatch-table row, no resident code.
   bank_try publishes the table base and count the bank needs to walk it.) */

void cmd_clear(int argc, char *argv[])
{
    (void)argc; (void)argv;
    chrout(CLEAR);
}

/* `ver` used to park its code and string in the KERNAL ROM because the BASIC ROM
   was full. It is not any more -- the KERNAL half is now the tight one -- so this
   is back where it belongs. */
#pragma code-name (push, "CODE")
#pragma rodata-name (push, "RODATA")
void cmd_ver(int argc, char *argv[])
{
    (void)argc; (void)argv;
    /* Brand + version; kept in step with the boot banner's version (reset.s). */
    puts_raw("Tardis DOS v0.2.38");
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
