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
#include "commands/overlay.h"

#define CR       0x0D            /* RETURN: submit the line                 */
#define DEL      0x14            /* DELETE: backspace                       */
#define CRSR_L   0x9D            /* cursor left  (move within the line)     */
#define CRSR_R   0x1D            /* cursor right                            */
#define CRSR_UP  0x91            /* cursor up    (recall older command)     */
#define CRSR_DN  0x11            /* cursor down  (recall newer command)     */
#define HOME     0x13            /* HOME: to the start of the input line    */
#define CLR      0x93            /* CLR (shift-HOME): wipe the input line   */
#define TAB      0x09            /* filename completion (a bare CTRL tap --
                                    irq.s ctrl_tap -- or CTRL+I)            */
#define PRINT_LO 0x20            /* printable PETSCII range we store/echo   */
#define PRINT_HI 0x7E
#define SWE_LO   0xDB            /* uppercase Swedish Ae/Oe/Aring ($DB-$DD), */
#define SWE_HI   0xDD            /* also storable/echoable (pet2scr -> $5B-$5D) */
#define LINEMAX  80             /* one 40-col line wraps to two; 80 is plenty */
#define HIST_N   8              /* commands remembered for up/down recall   */

/* The command table: name -> handler, walked in order both for dispatch and
   by `help`. A row is either a resident function or a BANK_CMD(n) entry index
   (see shell.h) -- the bank commands have NO resident code, only their row. Sorted alphabetically so `help` (which displays it column-major
   over three columns) reads naturally down each column. Lives in ROM and
   spends its bytes in the KERNAL ROM (RODATA2) to leave room in the smaller
   BASIC ROM, where the rest of the cc65 output sits. */
#pragma rodata-name (push, "RODATA2")
const struct command shell_commands[] = {
    { "about",  cmd_about  },
    { "basic",  cmd_basic  },
    { "bg",     cmd_bg     },
    { "border", cmd_border },
    { "cat",    cmd_cat    },
    { "cd",     cmd_cd     },
    { "clear",  cmd_clear  },
    { "cp",     cmd_cp     },
    { "dev",    cmd_device },
    { "device", cmd_device },
    { "devices", cmd_devices },
    { "dir",    BANK_CMD(0) },
    { "edit",   cmd_edit   },
    { "fload",  BANK_CMD(3) },
    { "font",   cmd_font   },
    { "help",   cmd_help   },
    { "less",   cmd_less   },
    { "load",   BANK_CMD(4) },
    { "ls",     BANK_CMD(1) },
    { "mv",     cmd_mv     },
    { "peek",   cmd_peek   },
    { "poke",   cmd_poke   },
    { "pwd",    BANK_CMD(2) },
    { "reset",  cmd_reset  },
    { "rm",     cmd_rm     },
    { "run",    cmd_run    },
    { "status", cmd_status },
    { "sys",    cmd_sys    },
    { "text",   cmd_text   },
    { "ver",    cmd_ver    },
};
const unsigned char shell_command_count =
    sizeof(shell_commands) / sizeof(shell_commands[0]);
#pragma rodata-name (pop)

/* The current command line, NUL-terminated by readline() and then carved into
   tokens in place by parse_line(). */
char line[LINEMAX + 1];         /* non-static: complete.s imports _line */

/* Command history: a ring of the last HIST_N submitted (non-empty) lines.
   `hist_next` is where the next one goes; `hist_count` is how many are valid.
   Up/down arrows in readline browse it.

   HIST_ROW is a POWER OF TWO on purpose. Indexing a 2-D array multiplies the
   row index by the row size, and a non-power-of-two row (this was LINEMAX + 1 =
   81) makes cc65 emit a 16-bit multiply -- which dragged mul.o + mul8.o, ~127
   bytes of runtime, into the resident ROM for four call sites here. A power of
   two is a shift instead, and 64-byte rows also use 136 bytes LESS RAM than 81
   did. Recalled lines are therefore capped at HIST_ROW - 1 characters, which
   costs nothing in practice: the NV blob already caps saved entries at 22. */
#define HIST_ROW 64             /* must stay a power of two -- see above */
static char hist[HIST_N][HIST_ROW];
static unsigned char hist_next;
static unsigned char hist_count;

/* Remember a submitted command line. */
static void history_add(const char *s)
{
    unsigned char i = 0;

    while (s[i] && i < HIST_ROW - 1) {
        hist[hist_next][i] = s[i];
        ++i;
    }
    hist[hist_next][i] = 0;
    hist_next = (hist_next + 1) & (HIST_N - 1);
    if (hist_count < HIST_N)
        ++hist_count;
}

/* The `browse`-th command back (1 = most recent), or "" for browse 0. */
static const char *history_get(unsigned char browse)
{
    if (browse == 0)
        return "";
    return hist[(hist_next + HIST_N - browse) & (HIST_N - 1)];
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

/* The prompt symbol main() shows (followed by a space). Fixed ">"; the `prompt`
   command that used to change it was removed. Kept as a writable[16] so the NV
   blob (v3) keeps its length-prefixed prompt field -- preserving the on-flash
   format so already-saved settings still load -- though it's always ">" now. */
static char prompt_str[16] = ">";

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

/* Print the prompt: "<dev>[ <name>]" then the prompt symbol and a space.
   Shared by main() and the completion candidate lister (which must reprint
   the prompt after dumping the matches). */
void print_prompt(void)         /* non-static: complete.s reprints the prompt
                                   after listing completion candidates */
{
    print_device_prefix();
    puts_raw(prompt_str);
    chrout(' ');
}

/* --- Filename TAB completion (docs/TAB-COMPLETION.md) -----------------------
 * The implementation is assembly (src/complete.s, KERNAL half): the first cut
 * was C right here and cc65 rendered it at ~1.3KB of BASIC ROM. ABI: line
 * length/cursor in CW_LEN/CW_POS ($02B1/$02B2), the buffer is `line` above. */
void tab_complete(void);
#define CW_LEN (*(unsigned char *)0x02B1)
#define CW_POS (*(unsigned char *)0x02B2)

/* Defined below with the NV machinery; readline's idle poll drives it. */
static void settings_idle(void);
static unsigned char idle_armed;

/* Read one line into `line`, echoing as we go; return its length.
 *
 * RETURN submits. Cursor left/right move within the line; printable characters
 * insert at the cursor; DELETE removes the character to its left, closing the
 * gap; HOME moves to the start of the input and CLR wipes the input (line-
 * editor semantics -- the screen-level HOME/CLR remain available to programs
 * via CHROUT, just not as prompt keystrokes). Any other control code is passed
 * straight to CHROUT but is not added to the line. */
static unsigned char readline(void)
{
    unsigned char len = 0;              /* characters in the line          */
    unsigned char pos = 0;              /* cursor index within it, 0..len  */
    unsigned char browse = 0;           /* history depth: 0 = the fresh line */
    unsigned char c, i;

    for (;;) {
        c = getin();
        if (c == 0) {
            settings_idle();            /* ~5s quiet + unsaved -> checkpoint */
            continue;
        }
        idle_armed = 0;                 /* typing re-arms the idle timer */
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
        if (c == TAB) {                 /* complete the word at the cursor */
            CW_LEN = len;
            CW_POS = pos;
            tab_complete();
            len = CW_LEN;
            pos = CW_POS;
            continue;
        }
        if (c == HOME) {                /* to the start of the INPUT, not the
                                           screen home CHROUT would do */
            while (pos > 0) {
                chrout(CRSR_L);         /* CRSR_L wraps rows, so a wrapped
                                           line walks back correctly */
                --pos;
            }
            continue;
        }
        if (c == CLR) {                 /* wipe the typed line, not the whole
                                           screen (the `clear` command and a
                                           programmatic $93 still do that) */
            replace_line("", &len, &pos);
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
        if ((c >= PRINT_LO && c <= PRINT_HI) || (c >= SWE_LO && c <= SWE_HI)) {
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

#pragma code-name (push, "CODE2")
#pragma rodata-name (push, "RODATA2")
/* JiffyDOS-style wedge aliases: rewrite the line in place before parsing.
 * "@" = status, "@$" = dir, "@#<n>" = device <n>, "/x" and "%x" = load x
 * (load always honors the file's embedded address, so / and % coincide),
 * "^x" = run x. The load/run forms quote the whole rest of the line, so
 * "/my game" loads MY GAME (JiffyDOS whole-rest semantics; the parser
 * accepts an unclosed quote). Runs after history_add, so recall shows what
 * was typed.
 * Anything else after "@" (raw DOS commands, "<-file" save) has no matching
 * command and is left alone -> "Command not found". */
static void wedge_rewrite(void)
{
    const char *cmd;
    unsigned char skip = 1;
    unsigned char n, k, i;

    switch (line[0]) {
    case '/':
    case '%':
        /* the whole rest of the line is the filename (JiffyDOS semantics);
           quote it so names with spaces survive the tokenizer -- the parser
           accepts an unclosed quote, so no trailing quote is needed */
        cmd = line[1] ? "load \"" : "load ";
        break;
    case '^':
        cmd = line[1] ? "run \"" : "run ";
        break;
    case '@':
        if (line[1] == 0) {
            cmd = "status";
            skip = 1;
        } else if (line[1] == '$' && line[2] == 0) {
            cmd = "dir";
            skip = 2;
        } else if (line[1] == '#') {
            cmd = "device ";
            skip = 2;
        } else {
            return;
        }
        break;
    default:
        return;
    }
    for (n = 0; line[n]; ++n)
        ;
    for (k = 0; cmd[k]; ++k)
        ;
    if ((unsigned char)(n - skip + k) > LINEMAX)
        return;                         /* rewritten line wouldn't fit */
    for (i = n + 1; i > skip; --i)      /* shift the rest right (incl. NUL) */
        line[i - 1 - skip + k] = line[i - 1];
    for (i = 0; i < k; ++i)
        line[i] = cmd[i];
}
#pragma rodata-name (pop)
#pragma code-name (pop)

/* Look up argv[0] in the command table and run its handler, or report that
   the command is unknown. An empty line (argc 0) just falls through. */
static void dispatch(struct command_line *cl)
{
    unsigned char i;

    if (cl->argc == 0)
        return;

    for (i = 0; i < shell_command_count; ++i) {
        if (streq(cl->argv[0], shell_commands[i].name)) {
            /* Data-driven dispatch: a row can name a BANK entry instead of a
               resident function, in which case there is no resident code for
               the command at all -- just this row. */
            if (IS_BANK_CMD(shell_commands[i].handler))
                bank_dispatch((unsigned char)(unsigned int)shell_commands[i].handler,
                              cl->argc, cl->argv);
            else
                shell_commands[i].handler(cl->argc, cl->argv);
            return;
        }
    }

    puts_raw("Command not found: ");
    puts_raw(cl->argv[0]);
    chrout(CR);
}

/* --- Persistent settings (colors + history) in the One ROM NV flash --------
 * The transport (src/rbcp/launch.s) runs the RBCP handshake; on a non-One-ROM
 * build it fails, nv_capability() returns 0, and everything here no-ops (so the
 * shell behaves exactly as before in VICE / a plain build). Blob at NV offset
 * 0: "TD" magic, version, 3 color bytes, font byte, length-prefixed prompt,
 * hist_count, then length-prefixed history lines (oldest first). Restore replays
 * history through history_add so the ring rebuilds exactly. To bound flash wear
 * we write only on a color/prompt change or every SAVE_EVERY commands (and on
 * `basic`, via cmd_basic, and on a font change). */
unsigned char nv_capability(void);
unsigned char nv_read(void);
unsigned char nv_write(void);
unsigned char font_select(unsigned char target);  /* fs.c: re-apply saved font */
unsigned char font_get(void);                      /* fs.c: current font (0/1) */
#define NV_MB_LEN (*(unsigned char *)0x02C4)
#define NV_MB_LO  (*(unsigned char *)0x02C5)
#define NV_MB_HI  (*(unsigned char *)0x02C6)

#define NV_MAGIC0    'T'
#define NV_MAGIC1    'D'
#define NV_VERSION   3          /* bumped: blob gained a length-prefixed prompt */
#define NV_BLOB_MAX  208        /* 7 hdr + (1+15) prompt + 1 hcount + 8*(1+22) */
#define NV_ENTRY_MAX 22         /* chars persisted per history line */
#define SAVE_EVERY   8          /* periodic history checkpoint, in commands */
#define VIC_BORDER   (*(unsigned char *)0xD020)
#define VIC_BG       (*(unsigned char *)0xD021)
#define COLOR_REG    (*(unsigned char *)0x0286)

static unsigned char nv_blob[NV_BLOB_MAX];
static unsigned char nv_ok;             /* NV present + writable (cached at boot) */
static unsigned char col_shadow[3];     /* last-saved border/bg/text */
static unsigned char cmds_since_save;


void settings_load(void)
{
    unsigned char i, n, k, j, hc;
    char tmp[LINEMAX + 1];

    nv_ok = nv_capability();
    if (!nv_ok)
        return;
    NV_MB_LEN = NV_BLOB_MAX;
    NV_MB_LO = (unsigned char)(unsigned int)&nv_blob[0];
    NV_MB_HI = (unsigned char)((unsigned int)&nv_blob[0] >> 8);
    if (nv_read() == 0 &&
        nv_blob[0] == NV_MAGIC0 && nv_blob[1] == NV_MAGIC1 &&
        nv_blob[2] == NV_VERSION) {
        VIC_BORDER = nv_blob[3] & 0x0F;
        VIC_BG     = nv_blob[4] & 0x0F;
        COLOR_REG  = nv_blob[5] & 0x0F;
        font_select(nv_blob[6] & 1);    /* re-apply font B (+ Swedish keys) */
        k = nv_blob[7];                 /* length-prefixed prompt: skip it (the */
        i = 8;                          /* prompt command was removed; it's fixed ">") */
        for (j = 0; j < k && i < NV_BLOB_MAX; ++j)
            ++i;
        hc = nv_blob[i++];
        for (n = 0; n < hc && n < HIST_N && i < NV_BLOB_MAX; ++n) {
            k = nv_blob[i++];
            j = 0;
            while (j < k && i < NV_BLOB_MAX && j < LINEMAX)
                tmp[j++] = nv_blob[i++];
            tmp[j] = 0;
            if (j > 0)
                history_add(tmp);
        }
    }
    /* shadow = the live colors, so the first command can't false-trigger a save */
    col_shadow[0] = VIC_BORDER & 0x0F;
    col_shadow[1] = VIC_BG & 0x0F;
    col_shadow[2] = COLOR_REG & 0x0F;
}

void settings_save(void)
{
    unsigned char i, n, oldest, k, j;
    const char *s;

    if (!nv_ok)
        return;
    nv_blob[0] = NV_MAGIC0;
    nv_blob[1] = NV_MAGIC1;
    nv_blob[2] = NV_VERSION;
    nv_blob[3] = VIC_BORDER & 0x0F;
    nv_blob[4] = VIC_BG & 0x0F;
    nv_blob[5] = COLOR_REG & 0x0F;
    nv_blob[6] = font_get();             /* persisted font (0 = A, 1 = B) */
    k = 0;                               /* length-prefixed prompt */
    while (prompt_str[k] && k < sizeof(prompt_str) - 1)
        ++k;
    nv_blob[7] = k;
    i = 8;
    for (j = 0; j < k; ++j)
        nv_blob[i++] = prompt_str[j];
    nv_blob[i++] = hist_count;
    oldest = (unsigned char)((hist_next + HIST_N - hist_count) & (HIST_N - 1));
    for (n = 0; n < hist_count; ++n) {
        s = hist[(unsigned char)((oldest + n) & (HIST_N - 1))];
        k = 0;
        while (s[k] && k < NV_ENTRY_MAX)
            ++k;
        nv_blob[i++] = k;
        for (j = 0; j < k; ++j)
            nv_blob[i++] = s[j];
    }
    NV_MB_LEN = i;                       /* used length only */
    NV_MB_LO = (unsigned char)(unsigned int)&nv_blob[0];
    NV_MB_HI = (unsigned char)((unsigned int)&nv_blob[0] >> 8);
    nv_write();                          /* best effort; a failed write just
                                            means this checkpoint is lost */
    col_shadow[0] = nv_blob[3];
    col_shadow[1] = nv_blob[4];
    col_shadow[2] = nv_blob[5];
    cmds_since_save = 0;
}

/* Idle checkpoint: the every-8-commands cadence loses short sessions (the
   user rarely types 8 commands before powering off), so once the prompt has
   sat idle ~5s with unsaved commands, save. One write per typing pause keeps
   flash wear far below save-per-command; typing re-arms the timer, so the
   RBCP session (~100ms) never lands mid-keystroke -- and the IRQ keyboard
   scan buffers anything typed during it regardless. Jiffies from the 24-bit
   IRQ clock at $A0 (TIME+1/TIME+2 = high/low of the 16-bit tail; the
   non-atomic two-byte read is at worst one tick off, which is harmless). */
#define JIFFY16() ((unsigned int)(*(volatile unsigned char *)0xA1) << 8 \
                   | *(volatile unsigned char *)0xA2)
#define IDLE_SAVE_TICKS 300     /* ~5s at 60 ticks/s */
static unsigned int idle_start;     /* idle_armed lives above readline */

static void settings_idle(void)
{
    if (!nv_ok || cmds_since_save == 0) {
        idle_armed = 0;
        return;
    }
    if (!idle_armed) {
        idle_start = JIFFY16();
        idle_armed = 1;
        return;
    }
    if ((unsigned int)(JIFFY16() - idle_start) >= IDLE_SAVE_TICKS) {
        idle_armed = 0;
        settings_save();        /* resets cmds_since_save -> won't refire */
    }
}

/* After a non-empty command: save now if a color changed, else once per
   SAVE_EVERY commands (a checkpoint that bounds the flash-write rate). */
static void settings_after_command(void)
{
    if (!nv_ok)
        return;
    if ((VIC_BORDER & 0x0F) != col_shadow[0] ||
        (VIC_BG & 0x0F) != col_shadow[1] ||
        (COLOR_REG & 0x0F) != col_shadow[2])
        settings_save();
    else if (++cmds_since_save >= SAVE_EVERY)
        settings_save();
}

void main(void)
{
    struct command_line cl;
    unsigned char n;

#ifndef TARGET_C128
    /* TARGET_C128 (C128 C64-mode build): both of these do One ROM RBCP -- settings_load
       probes NV, identify_boot_device fetches the files overlay -- which hang on a
       firmware with no host-control plugin. Skipped there; the prompt then shows the
       bare device number and colors stay at the reset.s defaults. */
    settings_load();                     /* apply saved colors + replay history */
    identify_boot_device();              /* "8: meatloaf>" from the first prompt */
#endif
    for (;;) {
        print_prompt();
        n = readline();
        wedge_rewrite();                 /* "@$" -> "dir", "/x" -> "load x", ... */
        parse_line(line, &cl);
        dispatch(&cl);
        if (n > 0)                       /* skip empty RETURNs */
            settings_after_command();
    }
}
