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
#include "commands/fs.h"

#define CR       0x0D            /* RETURN: submit the line                 */
#define DEL      0x14            /* DELETE: backspace                       */
#define CRSR_L   0x9D            /* cursor left  (move within the line)     */
#define CRSR_R   0x1D            /* cursor right                            */
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
    { "ls",    cmd_ls    },
    { "load",  cmd_load  },
    { "run",   cmd_run   },
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

/* Redraw the whole input line and leave the cursor at column `target`.
 *
 * `cur` is the cursor's current offset from the line start; we step back there,
 * reprint all `len` characters plus one trailing space (to wipe a character a
 * delete just removed), then step the cursor to `target`. Used only for edits
 * inside the line -- appends and end-deletes take a cheaper path. Assumes the
 * line fits on one 40-column row (cursor-left/right don't wrap). */
static void redraw_line(unsigned char cur, unsigned char len, unsigned char target)
{
    unsigned char i;

    for (i = 0; i < cur; ++i)
        chrout(CRSR_L);                 /* back to the start of the input */
    for (i = 0; i < len; ++i)
        chrout(line[i]);                /* reprint the line */
    chrout(' ');                        /* erase the just-vacated trailing cell */
    for (i = len + 1; i > target; --i)
        chrout(CRSR_L);                 /* park the cursor at `target` */
}

/* Read one line into `line`, echoing as we go; return its length.
 *
 * RETURN submits. Cursor left/right move within the line; printable characters
 * insert at the cursor; DELETE removes the character to its left, closing the
 * gap. Any other control code is passed straight to CHROUT (so e.g. a
 * clear-screen still works as you type) but is not added to the line. */
static unsigned char readline(void)
{
    unsigned char len = 0;              /* characters in the line          */
    unsigned char pos = 0;              /* cursor index within it, 0..len  */
    unsigned char c, i;

    for (;;) {
        c = getin();
        if (c == 0)
            continue;                   /* nothing waiting */
        if (c == CR) {
            chrout(CR);
            line[len] = 0;
            return len;
        }
        if (c == CRSR_L) {
            if (pos > 0) {
                chrout(CRSR_L);
                --pos;
            }
            continue;
        }
        if (c == CRSR_R) {
            if (pos < len) {
                chrout(CRSR_R);
                ++pos;
            }
            continue;
        }
        if (c == DEL) {
            if (pos == 0)
                continue;               /* nothing to the left of the cursor */
            if (pos == len) {           /* common case: erase at the end */
                --len;
                --pos;
                chrout(DEL);
            } else {                    /* delete inside the line, close the gap */
                for (i = pos; i < len; ++i)
                    line[i - 1] = line[i];
                --len;
                redraw_line(pos, len, pos - 1);
                --pos;
            }
            continue;
        }
        if (c >= PRINT_LO && c <= PRINT_HI) {
            if (len >= LINEMAX)
                continue;               /* line full */
            if (pos == len) {           /* common case: append */
                line[len++] = c;
                chrout(c);
                ++pos;
            } else {                    /* insert, pushing the tail right */
                for (i = len; i > pos; --i)
                    line[i] = line[i - 1];
                line[pos] = c;
                ++len;
                redraw_line(pos, len, pos + 1);
                ++pos;
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
