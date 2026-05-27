/* shell.c - the shell's main loop, line reader, and command dispatch.
 *
 * main() prints a prompt, reads a line, tokenizes it, and dispatches to a
 * handler from the command table below; an unrecognized command reports
 * "Command not found". I/O goes through the KERNAL entry points via the thin
 * asm shims in c_io.s -- we deliberately avoid cc65's conio, which assumes the
 * stock C64 KERNAL we replaced.
 *
 * The encoding is ASCII-consistent: letter keys arrive as lowercase ASCII
 * (the boot default is the lowercase charset), CHROUT draws them lowercase,
 * and our string literals are plain ASCII -- so command names below are
 * lowercase to match what the user types, and no translation is needed.
 */
#include "shell.h"
#include "parser.h"
#include "commands/builtins.h"

#define CR       0x0D            /* RETURN: submit the line                 */
#define DEL      0x14            /* DELETE: backspace                       */
#define PRINT_LO 0x20            /* printable PETSCII range we store/echo   */
#define PRINT_HI 0x7E
#define LINEMAX  80             /* one 40-col line wraps to two; 80 is plenty */

/* The command table: name -> handler, walked in order both for dispatch and
   by `help`. It is const, so it lives in ROM (RODATA). Add a command here and
   help picks it up automatically. */
const struct command shell_commands[] = {
    { "help",  cmd_help  },
    { "clear", cmd_clear },
    { "echo",  cmd_echo  },
    { "ver",   cmd_ver   },
    { "exit",  cmd_exit  },
};
const unsigned char shell_command_count =
    sizeof(shell_commands) / sizeof(shell_commands[0]);

/* The current command line, NUL-terminated by readline() and then carved into
   tokens in place by parse_line(). */
static char line[LINEMAX + 1];

/* Compare two NUL-terminated strings for equality. Input and the table names
   are both lowercase ASCII, so a plain byte compare suffices -- no case
   folding needed. */
static unsigned char streq(const char *a, const char *b)
{
    while (*a && *a == *b) {
        ++a;
        ++b;
    }
    return *a == *b;            /* both hit NUL together -> equal */
}

void puts_raw(const char *s)
{
    while (*s)
        chrout(*s++);
}

/* Read one line into `line`, echoing as we go; return its length.
 *
 * RETURN submits, DELETE backspaces, printable characters are stored and
 * echoed. Any other control code is passed straight to CHROUT (so e.g. a
 * clear-screen still works as you type) but is not added to the line. */
static unsigned char readline(void)
{
    unsigned char len = 0;
    unsigned char c;

    for (;;) {
        c = getin();
        if (c == 0)
            continue;                   /* nothing waiting */
        if (c == CR) {
            chrout(CR);
            line[len] = 0;
            return len;
        }
        if (c == DEL) {
            if (len > 0) {
                --len;
                chrout(DEL);
            }
            continue;
        }
        if (c >= PRINT_LO && c <= PRINT_HI) {
            if (len < LINEMAX) {
                line[len++] = c;
                chrout(c);              /* echo */
            }
            continue;
        }
        chrout(c);                      /* other control code: act, don't store */
    }
}

/* Look up argv[0] in the command table and run its handler, or report that
   the command is unknown. An empty line (argc 0) just falls through. */
static void dispatch(struct command_line *cl)
{
    unsigned char i;

    if (cl->argc == 0)
        return;

    for (i = 0; i < shell_command_count; ++i) {
        if (streq(cl->argv[0], shell_commands[i].name)) {
            shell_commands[i].handler(cl->argc, cl->argv);
            return;
        }
    }

    puts_raw("Command not found: ");
    puts_raw(cl->argv[0]);
    chrout(CR);
}

void main(void)
{
    struct command_line cl;

    for (;;) {
        chrout('>');
        chrout(' ');
        readline();
        parse_line(line, &cl);
        dispatch(&cl);
    }
}
