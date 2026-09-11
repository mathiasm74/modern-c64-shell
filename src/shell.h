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
/* A command is either RESIDENT (handler is a real function pointer) or lives in
   a BANK (handler holds a small entry index instead -- see BANK_CMD below).
   Data-driven dispatch: a bank command needs no resident thunk at all, so
   adding one costs only this 4-byte row plus its name. The table stays unified
   and sorted, which keeps `help` listing everything from one place and keeps
   "Command not found" honest -- a bank command the user typed is KNOWN, it just
   may be unreachable, which is a different message. */
struct command {
    const char *name;
    void (*handler)(int argc, char *argv[]);
};

/* Mark a table row as "run entry `e` of bank `b`". Real code never lives in
   page zero, so a handler value below $0100 cannot be a function pointer and is
   unambiguous. dispatch() (shell.c) routes these through bank_dispatch().
   Packing the bank into the high bits keeps a row 4 bytes no matter which bank
   a command lives in. */
#define BANK_DISK        0
#define BANK_UTIL        1
#define BANK_FILES       2
#define BANK_EDIT        3
#define BANK_CMD(b, e)   ((void (*)(int, char **))(((b) << 5) | (e)))
#define IS_BANK_CMD(fn)  ((unsigned int)(fn) < 0x0100)

/* fs.c: run bank entry `n`, first publishing what every bank command needs
   (the default device and its remembered name) and the argc/argv the bank
   reads its own arguments from. Reports if the bank is unreachable. */
void bank_dispatch(unsigned char entry, int argc, char *argv[]);

/* The same, but returns the failure instead of reporting it -- for callers that
   should stay silent when the bank is unreachable (TAB completion: a keystroke
   that quietly does nothing beats an error message mid-line). */
unsigned char bank_try(unsigned char entry, int argc, char *argv[]);

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
void print_uint(unsigned int n);        /* fs.c */

/* Persist colors + history to the One ROM NV flash (shell.c). No-op when NV
   isn't available. cmd_exit calls this to snapshot before swapping ROMs. */
void settings_save(void);

#endif /* SHELL_H */
