/* shell.h - shared shell types and the I/O the C modules lean on.
 *
 * The dispatch table lives in shell.c; cmd_help walks it through the extern
 * declarations here. The I/O helpers are how every C module reaches the
 * screen and keyboard without cc65's conio (which assumes the stock KERNAL
 * we replaced) -- chrout/getin are the asm shims in c_io.s, puts_raw is a
 * thin C convenience defined in shell.c.
 */
#ifndef SHELL_H
#define SHELL_H

/* One dispatch-table entry: a command name and the handler it runs. */
struct command {
    const char *name;
    void (*handler)(int argc, char *argv[]);
};

/* The dispatch table and its length, defined in shell.c. cmd_help reads them
   so `help` lists whatever commands are registered, with no second list to
   keep in sync. */
extern const struct command shell_commands[];
extern const unsigned char shell_command_count;

/* KERNAL I/O via the asm shims in c_io.s. */
void chrout(unsigned char c);
unsigned char getin(void);

/* Print a NUL-terminated string through CHROUT. */
void puts_raw(const char *s);

/* Set the shell prompt string (shown by main(), defined in shell.c). */
void set_prompt(const char *s);

#endif /* SHELL_H */
