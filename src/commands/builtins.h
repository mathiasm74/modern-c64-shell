/* builtins.h - the trivial built-in commands (see builtins.c).
 *
 * Each follows the dispatch-table handler signature; the shell.c command
 * table maps a name to one of these. */
#ifndef BUILTINS_H
#define BUILTINS_H

void cmd_help(int argc, char *argv[]);   /* list all registered commands */
void cmd_clear(int argc, char *argv[]);  /* clear the screen             */
void cmd_ver(int argc, char *argv[]);    /* print name and version       */
void cmd_reset(int argc, char *argv[]);  /* reboot the shell             */

#endif /* BUILTINS_H */
