/* mem.c - peek and poke: thin resident thunks.
 *
 * The bodies (number parse, memory access, the hexdump and hex printing) live
 * in the files overlay (cmds 12/13), so they cost overlay flash, not the 16KB
 * ROM. Numbers are decimal by default, hex when prefixed with '$' -- the C64
 * convention; the overlay does the parsing. Args (addr / count / value) ride
 * the standard files mailbox via files_run.
 */
#include "shell.h"
#include "commands/mem.h"
#include "commands/overlay.h"

void cmd_peek(int argc, char *argv[])
{
    files_run(12, argc > 1 ? argv[1] : 0, argc > 2 ? argv[2] : 0);
}

void cmd_poke(int argc, char *argv[])
{
    files_run(13, argc > 1 ? argv[1] : 0, argc > 2 ? argv[2] : 0);
}
