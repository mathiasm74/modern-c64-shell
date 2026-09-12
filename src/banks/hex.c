/* hex.c - the HEX EDITOR bank (docs/ROM-EXPANSION.md).
 *
 * A byte editor: the file is loaded whole into user RAM, shown as an address
 * column plus hex and PETSCII panes, edited in place, and written back.
 *
 * WHY WHOLE-FILE, and not a paged window over the file: a CBM drive has no
 * cheap seek. Sequential files read start to end; random access needs REL
 * files or U1/U2 block commands, which network drives generally do not offer.
 * A paged design would therefore re-read from the start for every scroll. RAM
 * is the resource we actually have (~37KB here), so we spend it.
 *
 * Layout, 40 columns:
 *     row 0      title: name, offset, modified flag
 *     rows 1-23  ADDR  xx xx xx xx xx xx xx xx  cccccccc
 *     row 24     key help / messages
 *
 * Bank rules (cfg/hex_bank.cfg): code+rodata are served ROM at $A000, so
 * nothing here may write $A000-$BFFF; the writable state is DATA/BSS in the
 * shared bank RAM window. The document lives at $0800 in USER RAM, exactly as
 * the text editor's does.
 */

/* crt0_hex.s: the KERNAL entry points, the only I/O a bank has. */
void __fastcall__ k_chrout(unsigned char c);
unsigned char k_getin(void);
void __fastcall__ k_setlfs(unsigned char dev, unsigned char sa);
void __fastcall__ k_setnam(const char *name, unsigned char len);
unsigned char k_open(void);
void k_close(void);
unsigned char k_chkin(void);
unsigned char k_chkout(void);
void k_clrchn(void);
unsigned char k_chrin(void);

/* Resident display helper (svc 12): PETSCII -> screen code for any byte,
   including the reverse-video rule for control codes. Shared with the text
   editor rather than duplicated -- see src/screen.s. */
unsigned char __fastcall__ svc_scr_display(unsigned char c);

/* ...but the character pane does NOT use that rule for control codes.
 *
 * scr_display renders $00-$1F and $80-$9F in reverse video -- $01 as a reversed
 * `a`, $02 as a reversed `b` -- which is the C64's own quote-mode convention and
 * exactly right for the TEXT editor, where a colour code embedded in a BASIC
 * string has to be visible AND distinguishable from the other codes. It is wrong
 * here: in a hex dump those glyphs read as text when they are not text, so a real
 * string does not stand out from the control bytes around it. Nothing is lost by
 * dropping them either, because the hex pane one column over already shows the
 * exact value. So the pane follows the usual hex-editor convention -- a `.` for
 * anything unprintable.
 *
 * Printable means $20-$7E and $A0-$FF. The high range is the PETSCII graphics set
 * and those are real glyphs worth seeing -- but note this shell runs the
 * LOWERCASE charset, where screen codes $41-$5A are uppercase letters rather than
 * graphics, so PETSCII $C1-$DA draw as A-Z and only $A0-$BF (plus a few strays)
 * draw as the box/bar set. That is the charset, not a mapping bug: stock BASIC
 * shows the graphics because it runs the uppercase/graphics charset.
 */
#define DOT_SCR  0x2E                   /* screen code for '.' */

static unsigned char char_cell(unsigned char b)
{
    if ((b >= 0x20 && b <= 0x7E) || b >= 0xA0)
        return svc_scr_display(b);
    return DOT_SCR;
}

#define SCREEN   ((unsigned char *)0x0400)
#define CRAM     ((unsigned char *)0xD800)
#define TEXT_COLOR (*(unsigned char *)0x0286)   /* the shell's current colour */
#define VIC_BG     (*(unsigned char *)0xD021)
#define COL_FOCUS  0x01                 /* white: the cell being edited */
#define COL_MIRROR 0x0F                 /* light grey: the same byte, other pane */
#define COL_EDITED 0x07                 /* yellow: a byte changed this session */
#define DATA_LO    5                    /* first column of the hex pane */
#define DATA_HI    37                   /* last column of the PETSCII pane */

/* The two panes' colour, chosen from the background once at startup (see
   pane_color below). Declared up here because the cursor helpers restore it. */
static unsigned char col_data;
#define COLS     40
#define ROWS     22                     /* screen rows 1..22 hold the dump */
#define HELPROW  23                     /* permanent legend */
#define MSGROW   24                     /* legend line 2, and where msg() writes.
                                           Two lines: the editor grew enough
                                           commands that one 40-column row could
                                           not name them, and an unadvertised
                                           binding is one nobody finds -- the
                                           lesson from the CTRL-tap completion. */
#define PAGE     ((unsigned int)ROWS * BPR)
#define PATMAX   16                     /* longest search pattern */
#define CTRL_Z   0x1A                   /* undo */
#define UNDO_N   128                    /* keystrokes of undo (power of two, so
                                           the ring index is an AND) */
#define BPR      8                      /* bytes per row */
#define STREG    (*(unsigned char *)0x90)

/* The document. Starts where a loaded program would; stops short of the bank
   RAM window ($9D00), which is where our own stack and BSS live -- growing
   into it would overwrite the editor while it runs. */
#define BUF      ((unsigned char *)0x0800)
#define BUFMAX   0x9400U

/* Which bytes have been changed, one bit each, so they can be drawn in yellow.
 *
 * SPARSE, in chunks: a flat bitmap over the whole document cost an eighth of the
 * file -- up to 4.7KB -- for a display nicety, and it was paid in full whether
 * one byte was edited or ten thousand. Editing is local, so instead the file is
 * divided into EDCHUNK-byte chunks and a chunk's 8 bytes of bitmap are allocated
 * from a small pool only when something in it is actually edited. A directory
 * maps chunk -> block, or $FF for "nothing edited in there".
 *
 *   directory   EDCHUNKS bytes (one per chunk, covering the whole buffer)
 *   pool        EDBLOCKS * (EDCHUNK/8) bytes
 *
 * That is 1104 bytes fixed instead of up to 4736, and because it no longer
 * scales with the file, tracking now survives to ~36.8KB rather than ~33.6KB --
 * so only files within about a kilobyte of the maximum lose the highlight.
 *
 * EDCHUNK is 64 -- smaller than a screenful (184 bytes), which keeps the
 * granularity fine enough that a single edit does not claim a large block, and
 * makes every index a shift.
 *
 * It all still lives immediately PAST the document, because there is nowhere
 * else: the bank's BSS is a 256-byte window shared with every other bank
 * ($9D10-$9E0F), and $C000-$CFFF is spoken for (the settings blob, the RBCP
 * copy, the completion name cache, the run stub).
 *
 * A LIST of edited offsets was the other option and is worse: it has to be
 * searched per drawn cell, and a full repaint draws 184 of them, so even a
 * 64-entry list costs ~12k comparisons per scroll. This is two indexed loads.
 */
static void msg(const char *s);         /* defined below; mark_edited reports
                                           pool exhaustion through it */

#define EDCHUNK   64                    /* file bytes per chunk */
#define EDBLK     (EDCHUNK / 8)         /* bitmap bytes per chunk */
#define EDCHUNKS  (BUFMAX / EDCHUNK)    /* directory entries: 592 */
#define EDBLOCKS  64                    /* chunks trackable at once */
#define EDNONE    0xFF

static unsigned char pat[PATMAX];       /* the last search pattern... */
static unsigned char patlen;            /* ...so a bare RETURN repeats it */

/* UNDO. This editor only ever OVERWRITES a byte -- never inserts, never deletes,
 * because a hex editor must not change a file's length -- so a record is just
 * (offset, previous value) and costs three bytes. There is no tree of operations
 * to model and no length bookkeeping; that is what makes undo cheap enough to
 * have here at all.
 *
 * One record per KEYSTROKE, which in the hex pane means per nibble. That is the
 * right granularity: a mistyped digit is taken back by one ^Z, which is what the
 * hand expects, rather than losing the whole byte.
 *
 * The ring holds the last UNDO_N and drops the oldest, so it is bounded depth
 * rather than full history -- lives past the edit map, see edits_init.
 *
 * UNDO ALSO CLEARS THE YELLOW MARK when the byte is back where it started. The
 * first cut did not, on the reasoning that the mark meant "touched this session"
 * and that knowing the ON-DISK value would need a second copy of the file. That
 * was wrong: the ring already carries it. Records hold the value BEFORE each
 * write, so after popping one, if NO REMAINING record mentions that offset then
 * the value just restored is the one the file was loaded with -- and the mark
 * comes off. A byte edited three times keeps its mark for the first two undos and
 * loses it on the third, which is what you want. Same argument retires `modified`
 * when the ring empties, so undoing everything also drops the `*` and stops ^X
 * from asking. The one inexact case is a ring that has DROPPED records (`uevict`):
 * an evicted earlier edit to the same byte cannot be seen, so `modified` is left
 * set -- erring towards "you still have changes", never the other way.
 */
static unsigned char *uring;            /* UNDO_N * 3: off lo, off hi, old byte */
static unsigned char uhead;             /* next slot to write */
static unsigned char ucount;            /* records available to undo */
static unsigned char uevict;            /* the ring has dropped a record, so its
                                           history is no longer complete */

static unsigned char *edir;             /* chunk -> block, or EDNONE */
static unsigned char *epool;
static unsigned char eblocks;           /* blocks handed out */
static unsigned char efull;             /* pool exhausted, said so once */
static unsigned char track;             /* 0 = no room at all, no highlighting */

/* cc65 turns `1 << (off & 7)` into a shift loop; a table is smaller and flat. */
static const unsigned char bitmask[8] = { 1, 2, 4, 8, 16, 32, 64, 128 };

/* argc/argv published by the resident dispatcher (bank_dispatch in fs.c). */
#define BD_ARGC  (*(unsigned char *)0x03A0)
#define BD_ARGV  (*(char ***)0x03A1)
#define MB_DEV   (*(unsigned char *)0x02D1)

#define CR_CH    0x0D
#define K_LEFT   0x9D
#define K_RIGHT  0x1D
#define K_UP     0x91
#define K_DOWN   0x11
#define K_PANE   0x5E                   /* the up-arrow key: switch pane */
#define K_HOME   0x13
#define CTRL_X   0x18
#define CTRL_O   0x0F
#define TAB      0x09
#define CTRL_B   0x02                   /* page back  (vi's ^B) */
#define CTRL_F   0x06                   /* page forward (vi's ^F) */
#define CTRL_G   0x07                   /* go to address */
#define CTRL_W   0x17                   /* find (nano's "where is") */
#define K_STOP   0x03
#define K_DEL    0x14

static unsigned int flen;               /* bytes held */
static unsigned int pos;                /* cursor byte offset */
static unsigned int top;                /* first offset on screen */
static unsigned char nib;               /* 0 = high nibble, 1 = low */
static unsigned char pane;              /* 0 = hex, 1 = PETSCII */
static unsigned char modified;
static unsigned char fname[17];
static unsigned char fnlen;
static unsigned char iocmd[24];
static unsigned char msg_hold;

static unsigned char hexd(unsigned char n)
{
    n &= 0x0F;
    return (unsigned char)(n < 10 ? '0' + n : 'a' + (n - 10));
}

/* Hex digit value, or $FF if the key is not one. */
static unsigned char hexval(unsigned char c)
{
    if (c >= '0' && c <= '9')
        return (unsigned char)(c - '0');
    if (c >= 'a' && c <= 'f')
        return (unsigned char)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F')
        return (unsigned char)(c - 'A' + 10);
    return 0xFF;
}

static void edits_init(void)
{
    unsigned int i;

    track = 0;
    efull = 0;
    eblocks = 0;
    uhead = 0;
    ucount = 0;
    uevict = 0;
    if (flen == 0
        || flen + (EDCHUNKS + EDBLOCKS * EDBLK + UNDO_N * 3) > BUFMAX)
        return;                         /* no room past the document: neither */
    edir = BUF + flen;
    epool = edir + EDCHUNKS;
    uring = epool + EDBLOCKS * EDBLK;
    for (i = 0; i < EDCHUNKS; ++i)
        edir[i] = EDNONE;               /* the pool itself is cleared per block */
    track = 1;
}

/* Remember a byte's value BEFORE it is overwritten. */
static void undo_push(unsigned int off, unsigned char old)
{
    unsigned char *r;

    if (!track)
        return;
    r = uring + (unsigned int)uhead * 3;
    r[0] = (unsigned char)off;
    r[1] = (unsigned char)(off >> 8);
    r[2] = old;
    uhead = (unsigned char)((uhead + 1) & (UNDO_N - 1));
    if (ucount < UNDO_N)
        ++ucount;
    else
        uevict = 1;                     /* the oldest is dropped: history is now
                                           partial, which `modified` must respect */
}

/* Does any record still in the ring refer to this offset? If not, the value we
   just restored is the one the file was loaded with. */
static unsigned char still_pending(unsigned int off)
{
    unsigned char i, idx;
    unsigned char *r;

    idx = (unsigned char)((uhead + UNDO_N - ucount) & (UNDO_N - 1));
    for (i = 0; i < ucount; ++i) {
        r = uring + (unsigned int)idx * 3;
        if ((unsigned int)(r[0] | ((unsigned int)r[1] << 8)) == off)
            return 1;
        idx = (unsigned char)((idx + 1) & (UNDO_N - 1));
    }
    return 0;
}

static void mark_edited(unsigned int off)
{
    unsigned char *b;
    unsigned char blk, i;

    if (!track)
        return;
    blk = edir[off / EDCHUNK];
    if (blk == EDNONE) {
        if (eblocks >= EDBLOCKS) {
            /* More scattered regions than the pool holds. Say so once rather
               than silently stop marking -- an unmarked edit would otherwise
               look like the feature was broken. */
            if (!efull) {
                efull = 1;
                msg("too many edited regions to mark");
            }
            return;
        }
        blk = eblocks++;
        edir[off / EDCHUNK] = blk;
        b = epool + (unsigned int)blk * EDBLK;
        for (i = 0; i < EDBLK; ++i)
            b[i] = 0;
    }
    epool[(unsigned int)blk * EDBLK + (((unsigned char)off & (EDCHUNK - 1)) >> 3)]
        |= bitmask[(unsigned char)off & 7];
}

/* The colour a byte's cells should carry when the cursor is not on them. */
static void unmark_edited(unsigned int off)
{
    unsigned char blk;

    if (!track)
        return;
    blk = edir[off / EDCHUNK];
    if (blk != EDNONE)
        epool[(unsigned int)blk * EDBLK
              + (((unsigned char)off & (EDCHUNK - 1)) >> 3)]
            &= (unsigned char)~bitmask[(unsigned char)off & 7];
}

static unsigned char cell_color(unsigned int off)
{
    unsigned char blk;

    if (track) {
        blk = edir[off / EDCHUNK];
        if (blk != EDNONE
            && (epool[(unsigned int)blk * EDBLK
                      + (((unsigned char)off & (EDCHUNK - 1)) >> 3)]
                & bitmask[(unsigned char)off & 7]))
            return COL_EDITED;
    }
    return col_data;
}

static void clear_row(unsigned char *r)
{
    unsigned char i;

    for (i = 0; i < COLS; ++i)
        r[i] = 0x20;
}

static void put_str(unsigned char *r, const char *s)
{
    while (*s)
        *r++ = svc_scr_display((unsigned char)*s++);
}

static void put_hex16(unsigned char *r, unsigned int v)
{
    r[0] = svc_scr_display(hexd((unsigned char)(v >> 12)));
    r[1] = svc_scr_display(hexd((unsigned char)(v >> 8)));
    r[2] = svc_scr_display(hexd((unsigned char)(v >> 4)));
    r[3] = svc_scr_display(hexd((unsigned char)v));
}

static void msg(const char *s)
{
    clear_row(SCREEN + MSGROW * COLS);
    put_str(SCREEN + MSGROW * COLS, s);
    msg_hold = 1;
}

static void draw_help(void)
{
    /* `^` renders as the up-arrow glyph in the C64 charset (screen code $1E),
       which is exactly the key it names -- and also how the CTRL combinations
       read, since there is no caret glyph. The standalone one is the pane key. */
    clear_row(SCREEN + HELPROW * COLS);
    put_str(SCREEN + HELPROW * COLS, "^x quit ^o save ^ pane ^b/^f page");
    clear_row(SCREEN + MSGROW * COLS);
    put_str(SCREEN + MSGROW * COLS, "^g goto ^w find ^z undo 0-9a-f edit");
}

/* Also single-pass -- it is redrawn on every cursor move (the "at" field), so
   a clear-then-fill here would blink the title on every keystroke. */
static void draw_title(void)
{
    unsigned char *t = SCREEN;
    unsigned char i;

    put_str(t, "hex: ");
    for (i = 0; i < fnlen; ++i)
        t[5 + i] = svc_scr_display(fname[i]);
    for (i = (unsigned char)(5 + fnlen); i < 23; ++i)
        t[i] = 0x20;
    put_str(t + 23, "at ");
    put_hex16(t + 26, pos);
    t[30] = 0x20;
    put_str(t + 31, "of ");
    put_hex16(t + 34, flen);
    t[38] = 0x20;
    t[39] = modified ? svc_scr_display('*') : 0x20;
}

/* One dump row: ADDR then BPR bytes in hex, then the same bytes as PETSCII. */
/* Every cell is written EXACTLY ONCE, with its final value. It used to
   clear_row() first and then fill, and that transient blank is what the eye
   catches: the VIC is reading the screen the whole time we write it, so a
   cleared-then-refilled row flashes. Writing each cell once cannot flash. */
static void render_row(unsigned char r, unsigned int off)
{
    unsigned char *row = SCREEN + (r + 1) * COLS;
    unsigned char *crow = CRAM + (r + 1) * COLS;
    unsigned char i, b, blank, col;

    if (off > flen || (off >= flen && off != 0 && flen != 0)) {
        clear_row(row);                 /* past the end: blank, one pass */
        return;
    }
    put_hex16(row, off);
    row[4] = 0x20;
    for (i = 0; i < BPR; ++i) {
        blank = (unsigned char)(off + i >= flen);
        b = blank ? 0 : BUF[off + i];
        col = blank ? col_data : cell_color(off + i);
        row[5 + i * 3] = blank ? 0x20
                               : svc_scr_display(hexd((unsigned char)(b >> 4)));
        row[6 + i * 3] = blank ? 0x20 : svc_scr_display(hexd(b));
        row[7 + i * 3] = 0x20;          /* separator; i = BPR-1 lands on col 28 */
        row[30 + i] = blank ? 0x20 : char_cell(b);
        /* Colour follows the BYTE, so an edited one stays yellow in both panes
           as it scrolls -- the map is the only record, so the repaint must read
           it rather than rely on colour RAM surviving. */
        crow[5 + i * 3] = col;
        crow[6 + i * 3] = col;
        crow[30 + i] = col;
    }
    row[29] = 0x20;
    row[38] = 0x20;
    row[39] = 0x20;
}

/* Column of the cursor cell on its row, per pane. */
static unsigned char cursor_col(void)
{
    unsigned char i = (unsigned char)((pos - top) % BPR);

    if (pane)
        return (unsigned char)(30 + i);
    return (unsigned char)(5 + i * 3 + nib);
}

/* Where the SAME byte is shown in the other pane. From the hex pane that is one
   character cell; from the character pane it is the byte's two hex digits, so
   this returns a length as well -- "the corresponding cell" is a pair there. */
static unsigned char mirror_col(unsigned char *len)
{
    unsigned char i = (unsigned char)((pos - top) % BPR);

    if (pane) {
        *len = 2;
        return (unsigned char)(5 + i * 3);
    }
    *len = 1;
    return (unsigned char)(30 + i);
}

/* The cells the cursor currently owns: the focused one (reverse + white) and the
   same byte's companion in the other pane (light grey). Remembering them is what
   lets a cursor move touch a handful of cells instead of repainting the screen --
   and it is what lets the colours be PUT BACK, without which the cursor would
   leave a trail of white cells behind it. */
static unsigned char cur_r, cur_c, cur_shown, cur_mc, cur_ml;
static unsigned int cur_off;            /* which byte, so its colour can be
                                           restored -- col_data or yellow */

static void cursor_off(void)
{
    unsigned int base;
    unsigned char i, col;

    if (!cur_shown)
        return;
    base = (unsigned int)(cur_r + 1) * COLS;
    col = cell_color(cur_off);          /* NOT col_data: an edited byte goes
                                           back to yellow, not to the pane */
    SCREEN[base + cur_c] &= 0x7F;
    CRAM[base + cur_c] = col;
    for (i = 0; i < cur_ml; ++i)
        CRAM[base + cur_mc + i] = col;
    cur_shown = 0;
}

static void cursor_on(void)
{
    unsigned char r = (unsigned char)((pos - top) / BPR);
    unsigned int base;
    unsigned char i;

    if (r >= ROWS)
        return;
    cur_r = r;
    cur_c = cursor_col();
    cur_mc = mirror_col(&cur_ml);
    cur_off = pos;
    cur_shown = 1;
    base = (unsigned int)(r + 1) * COLS;
    SCREEN[base + cur_c] |= 0x80;
    CRAM[base + cur_c] = COL_FOCUS;
    for (i = 0; i < cur_ml; ++i)
        CRAM[base + cur_mc + i] = COL_MIRROR;
}

static void render(void)
{
    unsigned char r;
    unsigned int off = top;

    cursor_off();                       /* hand the old cells their colour back;
                                           render_row writes screen codes only,
                                           so colour RAM survives a repaint */
    draw_title();
    for (r = 0; r < ROWS; ++r) {
        render_row(r, off);
        off += BPR;
    }
    if (!msg_hold)
        draw_help();
    cursor_on();
}

/* A dimmer companion for each background colour, so the two data panes read as
   one block behind the address column and the cursor. The C64 palette has a
   genuine light/dark sibling only for some hues -- red/light red, green/light
   green, blue/light blue, brown/orange, the three greys -- and no arithmetic
   produces them (+8 works for red, green and blue and gives nonsense for the
   rest), so it is a table. Colours with no usable relative fall back to white,
   which is legible on anything. Indexed by the BACKGROUND, which is what the
   panes actually sit on. */
static const unsigned char pane_color[16] = {
    0x0C,       /* 0  black        -> medium grey */
    0x0C,       /* 1  white        -> medium grey (a light ground wants darker) */
    0x0A,       /* 2  red          -> light red    <- the shell's own scheme */
    0x01,       /* 3  cyan         -> white */
    0x01,       /* 4  purple       -> white */
    0x0D,       /* 5  green        -> light green */
    0x0E,       /* 6  blue         -> light blue */
    0x0C,       /* 7  yellow       -> medium grey (bright ground wants darker) */
    0x07,       /* 8  orange       -> yellow */
    0x08,       /* 9  brown        -> orange */
    0x01,       /* 10 light red    -> white */
    0x0C,       /* 11 dark grey    -> medium grey */
    0x0F,       /* 12 medium grey  -> light grey */
    0x01,       /* 13 light green  -> white */
    0x01,       /* 14 light blue   -> white */
    0x01,       /* 15 light grey   -> white */
};

static void fill_color(void)
{
    unsigned int i;
    unsigned char r;

    /* The shell's CURRENT text colour, not a guess. This used to hardcode $0E
       (light blue), which read as "the default" but is the bare machine's
       default, not this shell's -- against the dark-red background Tardis boots
       with, blue on red is nearly unreadable (hardware-reported). Taking $0286
       also means `text <n>` now applies to the editor like everywhere else. */
    for (i = 0; i < 1000; ++i)
        CRAM[i] = TEXT_COLOR;

    /* ...except the two data panes, which are dimmer so the address column, the
       cursor and its companion cell stand out of them. */
    col_data = pane_color[VIC_BG & 0x0F];
    for (r = 1; r <= ROWS; ++r)
        for (i = DATA_LO; i <= DATA_HI; ++i)
            CRAM[(unsigned int)r * COLS + i] = col_data;
}

/* Read a short line on the message row, echoing it with a block cursor.
   Returns the length, or 0xFF if cancelled (STOP or ^X). Modal: it owns the
   keyboard while it runs, which is what lets the character pane -- where every
   printable key is data -- still take typed input for a prompt. */
static unsigned char prompt_line(const char *label, unsigned char *buf,
                                 unsigned char max)
{
    unsigned char *row = SCREEN + MSGROW * COLS;
    unsigned char n = 0, c, i, col = 0;

    clear_row(row);
    put_str(row, label);
    while (label[col])
        ++col;

    for (;;) {
        for (i = 0; i <= max; ++i)      /* the typed text, then a block cursor */
            row[col + i] = (i < n) ? svc_scr_display(buf[i]) : 0x20;
        row[col + n] |= 0x80;

        do {
            c = k_getin();
        } while (!c);

        if (c == CR_CH)
            return n;
        if (c == K_STOP || c == CTRL_X)
            return 0xFF;
        if (c == K_DEL) {
            if (n)
                --n;
            continue;
        }
        if (n < max && c >= 0x20)
            buf[n++] = c;
    }
}

/* ^G: jump to an address. */
static void do_goto(void)
{
    unsigned char in[4];
    unsigned char n, i, d;
    unsigned int a = 0;

    n = prompt_line("goto $", in, 4);
    if (n == 0xFF || n == 0)
        return;
    for (i = 0; i < n; ++i) {
        d = hexval(in[i]);
        if (d == 0xFF) {
            msg("not a hex address");
            return;
        }
        a = (a << 4) | d;
    }
    if (flen == 0)
        return;
    if (a >= flen) {
        msg("past end of file");
        return;
    }
    pos = a;
    nib = 0;
    top = (pos / BPR) * BPR;            /* target row at the top: predictable */
}

/* Read a search pattern: "$" then hex byte pairs, else the text as typed. The
   `$` convention is the shell's own (peek/poke/sys), so it needs no explaining.
   A bare RETURN keeps the previous pattern, which is how you find the next
   occurrence without a second key binding. */
static unsigned char read_pattern(void)
{
    unsigned char in[PATMAX * 2];
    unsigned char n, i, hi, lo;

    n = prompt_line("find ", in, PATMAX * 2);
    if (n == 0xFF)
        return 0;
    if (n == 0)
        return patlen ? 1 : 0;

    if (in[0] == '$') {
        if (n < 3 || ((n - 1) & 1)) {
            msg("whole bytes only, e.g. $a90d");
            return 0;
        }
        patlen = 0;
        for (i = 1; i < n; i += 2) {
            hi = hexval(in[i]);
            lo = hexval(in[i + 1]);
            if (hi == 0xFF || lo == 0xFF) {
                msg("not hex");
                return 0;
            }
            pat[patlen++] = (unsigned char)((hi << 4) | lo);
        }
        return 1;
    }
    for (i = 0; i < n; ++i)
        pat[i] = in[i];
    patlen = n;
    return 1;
}

static unsigned char match_at(unsigned int at)
{
    unsigned char i;

    for (i = 0; i < patlen; ++i)
        if (BUF[at + i] != pat[i])
            return 0;
    return 1;
}

/* ^W: find the next occurrence, wrapping once so repeated finds walk the file
   and the last match leads back to the first. */
static void do_find(void)
{
    unsigned int last, at, scanned;

    if (!read_pattern())
        return;
    if (flen == 0 || patlen == 0 || patlen > flen) {
        msg("not found");
        return;
    }
    last = flen - patlen;               /* highest legal start offset */
    at = (pos < last) ? pos + 1 : 0;
    for (scanned = 0; scanned <= last; ++scanned) {
        if (match_at(at)) {
            pos = at;
            nib = 0;
            top = (pos / BPR) * BPR;
            return;                     /* the title's "at" says where */
        }
        at = (at < last) ? at + 1 : 0;
    }
    msg("not found");
}

/* ^Z: put the last overwritten byte back, and go to it -- being shown WHERE the
   change was undone matters as much as undoing it. */
static void do_undo(void)
{
    unsigned char *r;
    unsigned int off;

    if (!track) {
        msg("undo unavailable: file too large");
        return;
    }
    if (!ucount) {
        msg("nothing to undo");
        return;
    }
    uhead = (unsigned char)((uhead + UNDO_N - 1) & (UNDO_N - 1));
    --ucount;
    r = uring + (unsigned int)uhead * 3;
    off = r[0] | ((unsigned int)r[1] << 8);
    BUF[off] = r[2];
    pos = off;
    nib = 0;
    /* Back to the loaded value? Then it is no longer an edit, and must stop
       showing as one -- the mark is what tells you what you changed, so a stale
       one is worse than none. */
    if (!still_pending(off))
        unmark_edited(off);
    if (ucount == 0 && !uevict)
        modified = 0;                   /* everything undone: drop the `*` too */
    if (pos < top || pos >= top + PAGE)
        top = (pos / BPR) * BPR;
}

/* ^B / ^F: a whole window at a time, keeping the cursor on the same screen row
   so the eye does not have to re-find it. */
static void page_move(unsigned char forward)
{
    unsigned int within = pos - top;

    if (forward) {
        if (top + PAGE >= flen)
            return;                     /* already showing the last page */
        top += PAGE;
    } else {
        if (top == 0)
            return;
        top = (top >= PAGE) ? top - PAGE : 0;
    }
    pos = top + within;
    if (pos >= flen)
        pos = flen - 1;
    nib = 0;
}

/* Keep the cursor's row on screen -- and when it leaves, move a PAGE, not a
   line. Stepping off the bottom puts the cursor on the TOP row (so the scroll
   reveals a whole screen of later bytes) and stepping off the top puts it on the
   BOTTOM row. Line-at-a-time was the obvious reading of "keep it visible" and it
   is the wrong one here: it repaints all 23 rows to show ONE new line of bytes,
   so holding cursor-down repaints the screen per byte-row and crawls. */
static void ensure_visible(void)
{
    unsigned int row = pos / BPR;       /* the cursor's row within the file */

    if (pos < top) {                    /* off the top: cursor to the last row */
        top = (row < (ROWS - 1)) ? 0 : (row - (ROWS - 1)) * BPR;
        return;
    }
    if (pos >= top + (unsigned int)ROWS * BPR)
        top = row * BPR;                /* off the bottom: cursor to the top row */
}

static unsigned char build_iocmd(const char *mode, unsigned char replace)
{
    unsigned char n = 0, i;

    if (replace) {
        iocmd[n++] = '@';
        iocmd[n++] = '0';
        iocmd[n++] = ':';
    }
    for (i = 0; i < fnlen; ++i)
        iocmd[n++] = fname[i];
    while (*mode)
        iocmd[n++] = (unsigned char)*mode++;
    return n;
}

static void load_file(void)
{
    unsigned char n, c, st;

    flen = 0;
    /* By NAME ONLY: a hex editor must be able to open whatever the file is,
       PRG or SEQ, and a type suffix makes the drive report the other kind as
       missing. The load address of a PRG is part of the data here -- that is
       the point of a hex editor. */
    n = build_iocmd("", 0);
    STREG = 0;
    k_setlfs(MB_DEV, 2);
    k_setnam((const char *)iocmd, n);
    if (k_open()) {
        msg("open failed");
        return;
    }
    if (k_chkin()) {
        k_close();
        msg("open failed");
        return;
    }
    for (;;) {
        c = k_chrin();
        st = STREG;
        if (st & 0x83)
            break;                      /* device gone / timeout: drop c */
        if (st & 0x40) {                /* EOI: a 1541 clocks out a real final
                                           byte, Meatloaf synthesises a $00 with
                                           no byte behind it -- so only keep a
                                           non-zero one, as load_file does in
                                           the text editor. */
            if (c && flen < BUFMAX)
                BUF[flen++] = c;
            break;
        }
        if (flen < BUFMAX)
            BUF[flen++] = c;
    }
    k_clrchn();
    k_close();
    if (flen == 0)
        msg("new file");
}

static unsigned char save_file(void)
{
    unsigned int i;
    unsigned char n;

    n = build_iocmd(",p,w", 1);
    STREG = 0;
    k_setlfs(MB_DEV, 2);
    k_setnam((const char *)iocmd, n);
    if (k_open()) {
        msg("open failed");
        return 0;
    }
    if (k_chkout()) {
        k_close();
        msg("write failed");
        return 0;
    }
    for (i = 0; i < flen; ++i)
        k_chrout(BUF[i]);
    k_clrchn();
    k_close();
    if (STREG & 0x83) {
        msg("write error");
        return 0;
    }
    modified = 0;
    msg("wrote");
    return 1;
}

void hex_main(void)
{
    unsigned char c, v, edited = 0, erow = 0;
    unsigned int old_top;
    char **argv = BD_ARGV;

    flen = 0;
    pos = 0;
    top = 0;
    nib = 0;
    pane = 0;
    modified = 0;
    msg_hold = 0;

    fnlen = 0;
    if (BD_ARGC > 1) {
        while (argv[1][fnlen] && fnlen < 16) {
            fname[fnlen] = (unsigned char)argv[1][fnlen];
            ++fnlen;
        }
    }
    fname[fnlen] = 0;

    k_chrout(0x93);                     /* clear */
    fill_color();
    if (fnlen)
        load_file();
    else
        msg("usage: hex <name>");
    edits_init();                       /* needs flen, so after the load */
    render();

    for (;;) {
        c = k_getin();
        if (!c)
            continue;
        msg_hold = 0;

        if (c == CTRL_X) {
            /* SAME question, same answers, as the text editor -- this used to ask
               "discard changes? y/n", where `y` THREW THE CHANGES AWAY while `y`
               in the text editor SAVES them. Two editors reached the same way,
               from the same shell, with one key meaning opposite things: muscle
               memory from one destroys work in the other. Both ask nano's
               question now, and both treat any other key as cancel rather than
               looping until y or n (there was no way out of this prompt). */
            if (!modified) {
                k_chrout(0x93);
                return;
            }
            msg("save modified buffer? (y/n)");
            for (;;) {
                v = k_getin();
                if (v == 'y' || v == 'Y') {
                    if (fnlen && save_file()) {
                        k_chrout(0x93);
                        return;
                    }
                    if (!fnlen)
                        msg("no file name");
                    break;                  /* save failed: stay in the editor */
                }
                if (v == 'n' || v == 'N') {
                    k_chrout(0x93);
                    return;
                }
                if (v)
                    break;                  /* anything else: cancel */
            }
            msg_hold = 0;
            render();
            continue;
        }
        if (c == CTRL_O) {
            if (fnlen)
                save_file();
            else
                msg("no file name");
            render();
            continue;
        }
        if (c == CTRL_G) {
            do_goto();
            render();
            continue;
        }
        if (c == CTRL_W) {
            do_find();
            render();
            continue;
        }
        if (c == CTRL_Z) {
            do_undo();
            render();
            continue;
        }
        if (c == TAB || c == K_PANE) {
            /* Switching panes moves the cursor and nothing else: the same byte
               is shown, the same rows, the same title. It used to render() --
               all 23 rows -- which is why it felt slow (hardware-reported). The
               light path is two cells off and three cells on.
               K_PANE is the C64's up-arrow key, which is a real key you can find
               without being told; TAB still works (CTRL+I, or a bare CTRL tap)
               but nothing advertises it. The cost is that the character pane
               cannot type $5E itself -- enter that byte from the hex pane. */
            cursor_off();
            pane ^= 1;
            nib = 0;
            cursor_on();
            continue;
        }
        old_top = top;
        edited = 0;
        if (c == K_LEFT) {
            if (pane == 0 && nib) {
                nib = 0;
            } else if (pos) {
                --pos;
                nib = pane ? 0 : 1;
            }
        } else if (c == K_RIGHT) {
            if (pane == 0 && nib == 0 && pos < flen) {
                nib = 1;
            } else if (pos + 1 < flen) {
                ++pos;
                nib = 0;
            }
        } else if (c == K_UP) {
            if (pos >= BPR)
                pos -= BPR;
            nib = 0;
        } else if (c == K_DOWN) {
            if (pos + BPR < flen)
                pos += BPR;
            nib = 0;
        } else if (c == CTRL_F) {
            page_move(1);
        } else if (c == CTRL_B) {
            page_move(0);
        } else if (c == K_HOME) {
            pos = 0;
            top = 0;
            nib = 0;
        } else if (pane == 0) {
            v = hexval(c);
            if (v == 0xFF || pos >= flen)
                continue;
            /* Overwrite the nibble under the cursor, then step on -- a hex
               editor never inserts: the file keeps its length. */
            undo_push(pos, BUF[pos]);
            if (nib == 0)
                BUF[pos] = (unsigned char)((BUF[pos] & 0x0F) | (v << 4));
            else
                BUF[pos] = (unsigned char)((BUF[pos] & 0xF0) | v);
            modified = 1;
            mark_edited(pos);
            edited = 1;
            erow = (unsigned char)((pos - top) / BPR);
            if (nib == 0) {
                nib = 1;
            } else {
                nib = 0;
                if (pos + 1 < flen)
                    ++pos;
            }
        } else {
            /* PETSCII pane: the key IS the byte. */
            if (pos >= flen)
                continue;
            undo_push(pos, BUF[pos]);
            BUF[pos] = c;
            modified = 1;
            mark_edited(pos);
            edited = 1;
            erow = (unsigned char)((pos - top) / BPR);
            if (pos + 1 < flen)         /* step on, exactly as the hex pane does
                                           after its second nibble. This was lost
                                           in v0.2.13 when the light repaint path
                                           replaced the block that held it, so
                                           typing in the character pane stopped
                                           advancing (hardware-reported). */
                ++pos;
        }
        ensure_visible();

        /* A cursor move changes TWO cells (the old reverse cell and the new
           one) plus the title's "at" field. Repainting all 22 dump rows for
           that made the whole screen flicker on every keypress -- reported from
           hardware. Only a SCROLL actually moves the dump, so only a scroll
           earns a full repaint; an edit redraws the one row it changed. */
        if (top != old_top) {
            render();
        } else {
            cursor_off();
            if (edited && erow < ROWS)
                render_row(erow, top + (unsigned int)erow * BPR);
            draw_title();
            cursor_on();
        }
    }
}
