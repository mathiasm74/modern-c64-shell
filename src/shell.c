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
#include "commands/mem.h"
#include "commands/config.h"

#define CR       0x0D            /* RETURN: submit the line                 */
#define TAB      0x09            /* complete the command word               */
#define DEL      0x14            /* DELETE: backspace                       */
#define CRSR_L   0x9D            /* cursor left  (move within the line)     */
#define CRSR_R   0x1D            /* cursor right                            */
#define CRSR_UP  0x91            /* cursor up    (recall older command)     */
#define CRSR_DN  0x11            /* cursor down  (recall newer command)     */
#define PRINT_LO 0x20            /* printable PETSCII range we store/echo   */
#define PRINT_HI 0x7E
#define LINEMAX  80             /* one 40-col line wraps to two; 80 is plenty */
#define HIST_N   8              /* commands remembered for up/down recall   */

/* The command table: name -> handler, walked in order both for dispatch and
   by `help`. Sorted alphabetically so `help` (which displays it column-major
   over three columns) reads naturally down each column. Lives in ROM and
   spends its bytes in the KERNAL ROM (RODATA2) to leave room in the smaller
   BASIC ROM, where the rest of the cc65 output sits. */
#pragma rodata-name (push, "RODATA2")
const struct command shell_commands[] = {
    { "bg",     cmd_bg     },
    { "border", cmd_border },
    { "cat",    cmd_cat    },
    { "cd",     cmd_cd     },
    { "clear",  cmd_clear  },
    { "cp",     cmd_cp     },
    { "device", cmd_device },
    { "dir",    cmd_dir    },
    { "echo",   cmd_echo   },
    { "exit",   cmd_exit   },
    { "fload",  cmd_fload  },
    { "help",   cmd_help   },
    { "less",   cmd_less   },
    { "load",   cmd_load   },
    { "ls",     cmd_ls     },
    { "mv",     cmd_mv     },
    { "peek",   cmd_peek   },
    { "poke",   cmd_poke   },
    { "prompt", cmd_prompt },
    { "pwd",    cmd_pwd    },
    { "reset",  cmd_reset  },
    { "rm",     cmd_rm     },
    { "run",    cmd_run    },
    { "runstock", cmd_runstock },
    { "text",   cmd_text   },
    { "ver",    cmd_ver    },
};
const unsigned char shell_command_count =
    sizeof(shell_commands) / sizeof(shell_commands[0]);
#pragma rodata-name (pop)

/* The current command line, NUL-terminated by readline() and then carved into
   tokens in place by parse_line(). */
static char line[LINEMAX + 1];

/* Command history: a ring of the last HIST_N submitted (non-empty) lines.
   `hist_next` is where the next one goes; `hist_count` is how many are valid.
   Up/down arrows in readline browse it. */
static char hist[HIST_N][LINEMAX + 1];
static unsigned char hist_next;
static unsigned char hist_count;

/* Remember a submitted command line. */
static void history_add(const char *s)
{
    unsigned char i = 0;

    while (s[i] && i < LINEMAX) {
        hist[hist_next][i] = s[i];
        ++i;
    }
    hist[hist_next][i] = 0;
    hist_next = (hist_next + 1) % HIST_N;
    if (hist_count < HIST_N)
        ++hist_count;
}

/* The `browse`-th command back (1 = most recent), or "" for browse 0. */
static const char *history_get(unsigned char browse)
{
    if (browse == 0)
        return "";
    return hist[(hist_next + HIST_N - browse) % HIST_N];
}

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

/* The prompt symbol main() shows (followed by a space). Initialized -> DATA,
   so it survives reset; `prompt` changes it. */
static char prompt_str[16] = ">";

void set_prompt(const char *s)
{
    unsigned char i = 0;

    while (s[i] && i < sizeof(prompt_str) - 1) {
        prompt_str[i] = s[i];
        ++i;
    }
    prompt_str[i] = 0;
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

/* Replace the whole input line with `s` (a recalled history entry, or "").
 * Steps the cursor back to the line start, draws the new text, pads with
 * spaces over any leftover of the old (longer) line, and leaves the cursor at
 * the end. Updates *plen / *ppos. CRSR_L wraps rows, so wrapped lines work. */
static void replace_line(const char *s, unsigned char *plen, unsigned char *ppos)
{
    unsigned char i, n = 0;
    unsigned char oldlen = *plen;

    for (i = 0; i < *ppos; ++i)
        chrout(CRSR_L);                 /* back to the start of the input */
    while (s[n] && n < LINEMAX) {       /* copy and draw the new text */
        line[n] = s[n];
        chrout(line[n]);
        ++n;
    }
    line[n] = 0;
    for (i = n; i < oldlen; ++i)
        chrout(' ');                    /* wipe the tail of a longer old line */
    for (i = n; i < oldlen; ++i)
        chrout(CRSR_L);
    *plen = n;
    *ppos = n;
}

/* Tab-complete the command word against the dispatch table. Only acts on a
 * bare prefix at the end of the line (no space yet, cursor at the end); if
 * exactly one command name starts with it, the rest of that name plus a space
 * is appended. Ambiguous or no match does nothing. */
static void complete_command(unsigned char *plen, unsigned char *ppos)
{
    unsigned char i, n, matches, match;
    const char *name;

    if (*plen == 0 || *ppos != *plen)
        return;
    for (i = 0; i < *plen; ++i)
        if (line[i] == ' ')
            return;                     /* already past the command word */

    matches = 0;
    match = 0;
    for (i = 0; i < shell_command_count; ++i) {
        name = shell_commands[i].name;
        for (n = 0; n < *plen; ++n)
            if (name[n] != line[n])
                break;
        if (n == *plen) {               /* name starts with the typed prefix */
            ++matches;
            match = i;
        }
    }
    if (matches != 1)
        return;                         /* none, or ambiguous: leave it be */

    name = shell_commands[match].name;
    for (n = *plen; name[n] && *plen < LINEMAX; ++n) {
        line[*plen] = name[n];
        chrout(name[n]);
        ++(*plen);
    }
    if (*plen < LINEMAX) {              /* trailing space, ready for arguments */
        line[*plen] = ' ';
        chrout(' ');
        ++(*plen);
    }
    *ppos = *plen;
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
    unsigned char browse = 0;           /* history depth: 0 = the fresh line */
    unsigned char c, i;

    for (;;) {
        c = getin();
        if (c == 0)
            continue;                   /* nothing waiting */
        if (c == CR) {
            chrout(CR);
            line[len] = 0;
            if (len > 0)                /* don't remember empty lines */
                history_add(line);
            return len;
        }
        if (c == CRSR_UP) {             /* recall an older command */
            if (browse < hist_count) {
                ++browse;
                replace_line(history_get(browse), &len, &pos);
            }
            continue;
        }
        if (c == CRSR_DN) {             /* back toward the fresh line */
            if (browse > 0) {
                --browse;
                replace_line(history_get(browse), &len, &pos);
            }
            continue;
        }
        if (c == TAB) {
            complete_command(&len, &pos);
            continue;
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
        puts_raw(prompt_str);
        chrout(' ');
        readline();
        parse_line(line, &cl);
        dispatch(&cl);
    }
}
