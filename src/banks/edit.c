/* edit.c - a small nano-like full-screen text editor (tardis overlay).
 *
 * This whole file lives OUTSIDE the 16KB shell ROM: it's compiled to the
 * multi-page edit overlay (cfg/overlay_edit.cfg, entry via crt0.s) stored in
 * the One ROM's overlays flash set and fetched into $8800+ on first use.
 *
 * Fixed memory map (absolute regions, not link-time objects):
 *   $0800-$7FFF  text, as a gap buffer (30KB documents)
 *   $8000-$87FF  clipboard (line-based cut/copy, 2KB)
 *   $8800-$9CFF  this code (+rodata/data), $9D00+ bss, $9F00+ C stack
 *   $02D0        filename mailbox from the resident thunk: len, then chars
 *
 * Screen: row 0 title, rows 1-23 the text window, row 24 help/messages.
 * Long lines display truncated at 40 columns (the buffer is unaffected).
 *
 * Keys (nano-style; CTRL+letter arrives as ASCII control codes from the
 * keyboard driver): ^X exit, ^O save, ^K cut line, ^C copy line, ^U paste,
 * ^A/HOME line start, ^E line end, cursors, DEL, RETURN. Consecutive ^K/^C
 * on the same chain append whole lines to the clipboard, like nano's cut.
 *
 * Text encoding: lines end in CR ($0D); characters are the shell's
 * ASCII-consistent set, written to disk verbatim (SEQ files; `cat` shows
 * them as typed). Files are saved with "@0:name,s,w" (save-with-replace).
 *
 * Everything is (re)initialized in edit_main: a cached overlay re-runs with
 * last session's globals, and nothing zeroes our BSS for us.
 */

unsigned char __fastcall__ k_chrout(unsigned char c);
unsigned char k_getin(void);
void __fastcall__ k_setlfs(unsigned char dev, unsigned char sa);
void __fastcall__ k_setnam(const char *name, unsigned char len);
unsigned char k_open(void);
void k_close(void);
unsigned char k_chkin(void);
unsigned char k_chkout(void);
void k_clrchn(void);
unsigned char k_chrin(void);

#define BUF      ((unsigned char *)0x0800)
#define BUFSZ    0x7800U
#define CLIP     ((unsigned char *)0x8000)
#define CLIPSZ   0x0800U
#define SCREEN   ((unsigned char *)0x0400)
#define STREG    (*(volatile unsigned char *)0x90)
/* The editor reads its own argument now that it is a bank: the resident
   dispatcher publishes argc/argv (bank_dispatch in fs.c) and we pull the
   filename straight out, so `edit` needs no resident thunk at all -- just its
   dispatch-table row. */
#define BD_ARGC  (*(unsigned char *)0x03A0)
#define BD_ARGV  (*(char ***)0x03A1)

#define CR_CH    0x0D
#define K_DEL    0x14
#define K_LEFT   0x9D
#define K_RIGHT  0x1D
#define K_UP     0x91
#define K_DOWN   0x11
#define K_HOME   0x13
#define ROWS     23             /* text rows (screen rows 1..23) */
#define COLS     40

/* --- editor state (assigned in edit_main; see header comment) ----------- */
static unsigned int gs, ge;     /* gap [gs,ge); cursor = gs                 */
static unsigned int top;        /* logical offset of the top window line    */
static unsigned int cliplen;
static unsigned char modified, msg_hold, chain;  /* chain: 1 = cut/copy run */
static unsigned char fname[17];
static unsigned char fnlen;
static unsigned char sctab[96]; /* ASCII $20-$7F -> screen code             */

/* --- gap buffer ---------------------------------------------------------- */
static unsigned int doclen(void)
{
    return BUFSZ - (ge - gs);
}

static unsigned char chat(unsigned int i)
{
    return (i < gs) ? BUF[i] : BUF[i + (ge - gs)];
}

static void move_to(unsigned int p)
{
    while (gs > p) {
        --gs;
        --ge;
        BUF[ge] = BUF[gs];
    }
    while (gs < p) {
        BUF[gs] = BUF[ge];
        ++gs;
        ++ge;
    }
}

static void insert_ch(unsigned char c)
{
    if (gs == ge)
        return;                 /* buffer full */
    BUF[gs++] = c;
    modified = 1;
}

/* --- line geometry (logical offsets) ------------------------------------- */
static unsigned int line_start(unsigned int p)
{
    while (p > 0 && chat(p - 1) != CR_CH)
        --p;
    return p;
}

static unsigned int line_end(unsigned int p)  /* offset of CR or doclen */
{
    unsigned int dl = doclen();

    while (p < dl && chat(p) != CR_CH)
        ++p;
    return p;
}

/* --- screen -------------------------------------------------------------- */
static void build_sctab(void)
{
    unsigned char i, c;

    for (i = 0; i < 96; ++i) {
        c = 0x20 + i;
        if (c >= 'a' && c <= 'z')
            c -= 0x60;          /* lowercase -> $01-$1A */
        else if (c == '@')
            c = 0x00;
        else if (c >= 0x5B && c <= 0x5F)
            c -= 0x40;          /* [ \ ] ^ _ -> $1B-$1F */
        else if (c >= 0x60)
            c = 0x3F;           /* `, {|}~, DEL: no glyph, show '?' */
        sctab[i] = c;           /* $20-$3F and A-Z pass through */
    }
}

/* A PETSCII control code has no glyph, so show it the way the C64 shows one
   inside quotes: in reverse video. The screen code it reverses was MEASURED
   against the stock KERNAL (test_runstub::test_control_code_glyphs_match_the_
   kernal), because the obvious guess is wrong:

     $00-$1F  ->  screen code c          ($1C red    -> $1C reversed)
     $80-$9F  ->  screen code (c&$1F)+$40 ($9C purple -> $5C reversed)

   Masking to c & $7F -- which looks right -- maps red and purple to the SAME
   glyph, and likewise for the other seven pairs, so half the colours would be
   indistinguishable.

   The glyph still will not match a stock LIST: stock BASIC runs the
   uppercase/graphics charset and this shell runs the lowercase one, so the
   same screen code draws a different picture. The CODE is right; the font
   differs. */
static unsigned char ctrl_glyph(unsigned char c)
{
    if (c >= 0x80)
        return (unsigned char)(((c & 0x1F) + 0x40) | 0x80);
    return (unsigned char)(c | 0x80);
}

/* PETSCII graphics ($A0-$FF, C= + key) use the standard mapping -- $A0-$BF
   $A0-$BF -> screen $60-$7F and $C0-$FF -> screen $40-$7F. Same
   rule as pet2scr in screen.s; it covers the uppercase Swedish letters too. */
static unsigned char gfx_scrc(unsigned char c)
{
    return (unsigned char)(c >= 0xC0 ? c - 0x80 : c - 0x40);
}

static unsigned char scrc(unsigned char c)
{
    if (c < 0x20 || (c >= 0x80 && c <= 0x9F))
        return ctrl_glyph(c);
    if (c >= 0xA0)
        return gfx_scrc(c);
    if (c > 0x7F)
        return 0x3F;
    return sctab[c - 0x20];
}

static void put_str(unsigned char *dst, const char *s)
{
    while (*s)
        *dst++ = scrc(*s++);
}

static void clear_row(unsigned char *dst)
{
    unsigned char i;

    for (i = 0; i < COLS; ++i)
        dst[i] = 0x20;
}

/* We paint screen codes straight into screen RAM and never touch color RAM, so
   the editor inherits whatever colors were left behind (e.g. a green PRG name
   from `ls`). Paint the whole screen's color RAM with the current text color
   once at startup so the UI is uniform regardless of prior screen content. */
#define CRAM ((unsigned char *)0xD800)
static void fill_color(void)
{
    unsigned int i;
    unsigned char col = *(unsigned char *)0x0286;       /* KERNAL text color */

    for (i = 0; i < 25 * COLS; ++i)                      /* all 25 screen rows */
        CRAM[i] = col;
}

static void draw_help(void)
{
    clear_row(SCREEN + 24 * COLS);
    put_str(SCREEN + 24 * COLS, "^x exit ^o save ^k cut ^c copy ^v literal");
}

static void msg(const char *s)
{
    clear_row(SCREEN + 24 * COLS);
    put_str(SCREEN + 24 * COLS, s);
    msg_hold = 1;
}

static void draw_title(void)
{
    unsigned char *t = SCREEN;
    unsigned char i;

    clear_row(t);
    put_str(t, "edit: ");
    if (fnlen)
        for (i = 0; i < fnlen; ++i)
            t[6 + i] = scrc(fname[i]);
    else
        put_str(t + 6, "(new)");
    if (modified)
        put_str(t + 32, "modified");
}

/* Rows WRAP: a logical line longer than the window occupies as many display
   rows as it needs, rather than being cut off at column 40. BASIC lines run to
   80 characters, so without this the right-hand half of a listing is invisible
   and the cursor sticks against the edge.

   Everything below therefore works in display ROWS, not logical lines. A row
   ends at a CR or at COLS characters, whichever comes first; a row start is
   any offset a row begins at (every line start is one). Cursor up/down still
   move by logical LINE, which is what an editor of this kind should do. */

/* Start of the display row following the one beginning at rs. */
static unsigned int row_next(unsigned int rs)
{
    unsigned int dl = doclen(), p = rs;
    unsigned char c = 0;

    while (p < dl && c < COLS) {
        if (chat(p) == CR_CH)
            return p + 1;               /* past the CR */
        ++p;
        ++c;
    }
    return p;
}

/* Start of the display row containing p. */
static unsigned int row_start(unsigned int p)
{
    unsigned int rs = line_start(p), nx;

    for (;;) {
        nx = row_next(rs);
        if (nx > p || nx == rs)
            return rs;
        rs = nx;
    }
}

/* Draw one window row (screen row r+1) from row start p; returns the next
   row's start (or doclen when past the end). */
static unsigned int render_row(unsigned char r, unsigned int p)
{
    unsigned int dl = doclen();
    unsigned char *row = SCREEN + (r + 1) * COLS;
    unsigned char c = 0;
    unsigned char ch;

    while (p < dl && c < COLS) {
        ch = chat(p);
        if (ch == CR_CH) {
            ++p;                /* step past the CR; the row ends here */
            break;
        }
        row[c++] = scrc(ch);
        ++p;
    }
    while (c < COLS)
        row[c++] = 0x20;
    return p;
}

static void show_cursor(unsigned char crow, unsigned int rs)
{
    unsigned char ccol = (unsigned char)(gs - rs);

    if (ccol > COLS - 1)                /* only when the row is the last one */
        ccol = COLS - 1;
    SCREEN[(crow + 1) * COLS + ccol] |= 0x80;
}

/* Full redraw of the text window plus the cursor cell (inverted). Records
   the cursor's window row / line start so light-path updates (see the main
   loop) can repaint just that row on plain typing. */
static unsigned char cur_row;   /* cursor's window row after last render */
static unsigned int cur_ls;     /* cursor's line start after last render */

static void render(void)
{
    unsigned int p = top;
    unsigned char r;
    unsigned char crow = 255;
    unsigned int cl = row_start(gs);

    draw_title();
    for (r = 0; r < ROWS; ++r) {
        if (crow == 255 && p == cl)
            crow = r;           /* FIRST match only: past the end of the
                                   document p stops advancing and every
                                   later row would re-match */
        p = render_row(r, p);
    }
    if (!msg_hold)
        draw_help();
    if (crow != 255) {
        show_cursor(crow, cl);
        cur_row = crow;
        cur_ls = cl;
    }
}

/* Light path: the edit touched only the cursor's current line and cannot
   have scrolled -- repaint that one row (and the title when the modified
   flag just flipped). ~40 cells instead of ~960: no visible flicker. */
static void render_line(unsigned char flipped)
{
    if (flipped)
        draw_title();
    render_row(cur_row, cur_ls);
    show_cursor(cur_row, cur_ls);
}

/* Keep the cursor's display ROW inside the window. Counting CRs is not enough
   once rows wrap: a single long line can fill the window by itself. */
static void ensure_visible(void)
{
    unsigned int cl = row_start(gs);
    unsigned int p;
    unsigned char r;

    if (cl < top) {
        top = cl;
        return;
    }
    for (;;) {
        p = top;
        r = 0;
        while (p < cl && r < ROWS) {    /* how many rows down is the cursor? */
            p = row_next(p);
            ++r;
        }
        if (r < ROWS)
            return;
        top = row_next(top);            /* scroll down one row */
    }
}

/* --- clipboard ------------------------------------------------------------ */
/* Append the cursor's line (including its CR) to the clipboard; cut also
   deletes it. Consecutive cut/copy keystrokes keep appending (chain). */
static void clip_line(unsigned char cut)
{
    unsigned int ls = line_start(gs);
    unsigned int le = line_end(ls);
    unsigned int n, i;

    if (le < doclen())
        ++le;                   /* include the CR */
    n = le - ls;
    if (!chain)
        cliplen = 0;
    if (n == 0 || cliplen + n > CLIPSZ) {
        msg(n ? "clipboard full" : "nothing to cut");
        return;
    }
    for (i = 0; i < n; ++i)
        CLIP[cliplen + i] = chat(ls + i);
    cliplen += n;
    if (cut) {
        move_to(ls);
        ge += n;                /* the line sits after the gap: drop it */
        modified = 1;
    }
    chain = 1;
}

static void paste(void)
{
    unsigned int i;

    if (cliplen == 0) {
        msg("clipboard empty");
        return;
    }
    if (ge - gs < cliplen) {
        msg("buffer full");
        return;
    }
    for (i = 0; i < cliplen; ++i)
        BUF[gs++] = CLIP[i];
    modified = 1;
}

/* --- file I/O -------------------------------------------------------------- */
static unsigned char iocmd[24];

static unsigned char build_iocmd(const char *mode, unsigned char replace)
{
    unsigned char n = 0, i;

    if (replace) {              /* "@0:" save-with-replace prefix */
        iocmd[n++] = '@';
        iocmd[n++] = '0';
        iocmd[n++] = ':';
    }
    for (i = 0; i < fnlen; ++i)
        iocmd[n++] = fname[i];
    while (*mode)
        iocmd[n++] = *mode++;
    return n;
}

static void print_u16(char *dst, unsigned int v)
{
    char tmp[5];
    unsigned char n = 0;

    do {
        tmp[n++] = '0' + (v % 10);
        v /= 10;
    } while (v);
    while (n)
        *dst++ = tmp[--n];
    *dst = 0;
}

/* Prompt on the message row for a filename; 0 = cancelled. */
static unsigned char prompt_name(void)
{
    unsigned char *row = SCREEN + 24 * COLS;
    unsigned char n = 0, c;

    clear_row(row);
    put_str(row, "name: ");
    for (;;) {
        c = k_getin();
        if (!c)
            continue;
        if (c == CR_CH)
            break;
        if (c == 0x18 || c == 0x03)         /* ^X / ^C: cancel */
            return 0;
        if (c == K_DEL && n) {
            --n;
            row[6 + n] = 0x20;
        } else if (c >= 0x20 && c <= 0x7E && n < 16) {
            fname[n] = c;
            row[6 + n] = scrc(c);
            ++n;
        }
    }
    if (n == 0)
        return 0;
    fnlen = n;
    return 1;
}

/* Set when the buffer holds a listing expanded from a tokenized BASIC program
   (see load_file). save_file refuses while it is set: there is no tokenizer
   yet, so writing the listing back would replace the program with its source. */
/* ^V pressed: the NEXT key is inserted as text rather than obeyed. */
static unsigned char literal_next;

static unsigned char basic_mode;


/* --- BASIC V2 detokenizer ---------------------------------------------------
 *
 * A tokenized BASIC program is not text, so without this the editor could not
 * open one at all: it opens files as SEQ, and a PRG would simply not be found.
 *
 * Layout, from the load address ($0801) onward, per line:
 *     link lo/hi   address of the next line; $0000 ends the program
 *     line# lo/hi
 *     bytes...     < $80 literal PETSCII, >= $80 a keyword token
 *     $00          end of line
 *
 * We have to carry our own keyword table: the stock BASIC ROM is exactly what
 * this shell replaced, so there is nothing to borrow at runtime. Tokens run
 * $80..$CB contiguously, so the table is just the keywords in order -- each
 * stored with the high bit set on its LAST character, which is how Commodore
 * stored it too and saves a separator byte per entry.
 *
 * Bytes inside quotes are NOT tokens (BASIC does not tokenize inside a string),
 * so the walk tracks quote state and passes those through untouched.
 */
/* Raw file bytes are staged high in the buffer and the listing expands DOWN
   from 0, so the two never meet: detokenized text is 2-3x the size of the
   tokens it came from. */
#define RAWOFF   0x5000U
#define RAWMAX   (BUFSZ - RAWOFF)

#define TOK_FIRST 0x80
#define TOK_LAST  0xCB
#define TOK_PI    0xFF

static const char basic_kw[] =
    "EN\xC4" "FO\xD2" "NEX\xD4" "DAT\xC1" "INPUT\xA3" "INPU\xD4" "DI\xCD"
    "REA\xC4" "LE\xD4" "GOT\xCF" "RU\xCE" "I\xC6" "RESTOR\xC5" "GOSU\xC2"
    "RETUR\xCE" "RE\xCD" "STO\xD0" "O\xCE" "WAI\xD4" "LOA\xC4" "SAV\xC5"
    "VERIF\xD9" "DE\xC6" "POK\xC5" "PRINT\xA3" "PRIN\xD4" "CON\xD4"
    "LIS\xD4" "CL\xD2" "CM\xC4" "SY\xD3" "OPE\xCE" "CLOS\xC5" "GE\xD4"
    "NE\xD7" "TAB\xA8" "T\xCF" "F\xCE" "SPC\xA8" "THE\xCE" "NO\xD4"
    "STE\xD0" "\xAB" "\xAD" "\xAA" "\xAF" "\xDE" "AN\xC4" "O\xD2"
    "\xBE" "\xBD" "\xBC" "SG\xCE" "IN\xD4" "AB\xD3" "US\xD2" "FR\xC5"
    "PO\xD3" "SQ\xD2" "RN\xC4" "LO\xC7" "EX\xD0" "CO\xD3" "SI\xCE"
    "TA\xCE" "AT\xCE" "PEE\xCB" "LE\xCE" "STR\xA4" "VA\xCC" "AS\xC3"
    "CHR\xA4" "LEFT\xA4" "RIGHT\xA4" "MID\xA4" "G\xCF";

/* Append one character of listing text, never running into the staged raw. */
static void emit(unsigned char c)
{
    if (gs < RAWOFF)
        BUF[gs++] = c;
}

/* Append one keyword to the buffer. */
static void put_keyword(unsigned char tok)
{
    const char *p = basic_kw;
    unsigned char n = tok - TOK_FIRST;
    unsigned char c;

    while (n) {                         /* skip n entries; each ends high-bit set */
        while ((*p++ & 0x80) == 0)
            ;
        --n;
    }
    for (;;) {
        c = (unsigned char)*p++;
        emit((unsigned char)(c & 0x7F));
        if (c & 0x80)
            return;
    }
}

/* Expand a tokenized program in place: raw bytes are read from `raw` (length
   `n`), the listing text is written through the gap buffer. */
static void detokenize(unsigned char *raw, unsigned int n)
{
    unsigned int off = 2, line;
    unsigned char c, quoted;
    char num[6];
    unsigned char i;

    for (;;) {
        if (off + 3 >= n)
            break;
        if ((raw[off] | raw[off + 1]) == 0)
            break;                      /* $0000 link: end of program */
        off += 2;
        line = raw[off] | ((unsigned int)raw[off + 1] << 8);
        off += 2;

        print_u16(num, line);
        for (i = 0; num[i]; ++i)
            emit((unsigned char)num[i]);
        emit(' ');

        quoted = 0;
        while (off < n && (c = raw[off++]) != 0) {
            if (c == '"')
                quoted ^= 1;
            if (!quoted && c >= TOK_FIRST && c <= TOK_LAST)
                put_keyword(c);
            else
                emit(c);
        }
        emit(CR_CH);
    }
}

/* --- BASIC V2 tokenizer -----------------------------------------------------
 *
 * The inverse of detokenize(): turn the edited listing back into a program.
 * Without this, a loaded program could only be viewed -- writing the listing
 * back as text would replace it with its own source, which BASIC cannot run.
 *
 * Keyword matching is FIRST-MATCH IN TABLE ORDER, which is what BASIC does and
 * why the table's order matters: "INPUT#" precedes "INPUT" and "PRINT#"
 * precedes "PRINT", so the longer form wins where one is a prefix of another.
 * Input is folded to uppercase while comparing, so a listing typed in the
 * shell's lowercase reads the same as one that came from a real program.
 *
 * Inside quotes nothing is tokenized and nothing is folded: a string may
 * legitimately contain the letters of a keyword, and it may contain control
 * codes (cursor moves, colour changes) that must survive byte-for-byte.
 *
 * Two statements suspend tokenizing the same way BASIC's own CRUNCH does:
 * after REM to the end of the line, and after DATA to the next colon. Without
 * that, any keyword's letters appearing inside the text get eaten -- "DONE"
 * became D,<ON>,E -- which both changes the bytes of a program that merely
 * round-trips through the editor and breaks what READ returns from a DATA
 * item.
 */
#define TOK_DATA  0x83
#define TOK_REM   0x8F

/* Match a keyword at document offset i. Returns the token and sets *len to the
   characters consumed, or 0 if no keyword starts here. */
static unsigned char match_keyword(unsigned int i, unsigned int dl,
                                   unsigned char *len)
{
    const char *p = basic_kw;
    unsigned char tok = TOK_FIRST;
    unsigned char n, c, k;

    for (;;) {
        n = 0;
        for (;;) {
            k = (unsigned char)p[n];
            c = (i + n < dl) ? (unsigned char)chat(i + n) : 0;
            if (c >= 'a' && c <= 'z')
                c -= 32;
            if ((k & 0x7F) != c) {
                n = 0xFF;               /* mismatch: try the next keyword */
                break;
            }
            if (k & 0x80) {             /* high bit marks the last character */
                *len = n + 1;
                return tok;
            }
            ++n;
        }
        if (n == 0xFF) {
            while ((*p++ & 0x80) == 0)  /* skip this entry */
                ;
            if (tok == TOK_LAST)
                return 0;
            ++tok;
        }
    }
}

/* Tokenize the whole document into dst (at most `room` bytes). Returns the
   length written, or 0 after reporting why. */
static unsigned int tokenize(unsigned char *dst, unsigned int room)
{
    unsigned int i = 0, dl = doclen(), n = 0;
    unsigned int line, prev = 0, prevlink = 0xFFFF, addr;
    unsigned char c, quoted, tok, klen, digits, first = 1, literal;

    while (i < dl) {
        while (i < dl && ((c = chat(i)) == ' ' || c == CR_CH))
            ++i;                        /* blank lines and indentation */
        if (i >= dl)
            break;

        line = 0;
        digits = 0;
        while (i < dl) {
            c = chat(i);
            if (c < '0' || c > '9')
                break;
            /* line = line*10, as shifts: a 16-bit multiply would pull cc65's
               mul runtime into this bank for one expression. */
            line = (line << 3) + (line << 1) + (unsigned int)(c - '0');
            ++digits;
            ++i;
        }
        if (!digits) {
            msg("needs line numbers");
            return 0;
        }
        /* BASIC stores lines in ascending order and the link chain assumes it.
           Refuse rather than write a program that lists wrongly. */
        if (!first && line <= prev) {
            msg("lines out of order");
            return 0;
        }
        prev = line;
        first = 0;
        if (i < dl && chat(i) == ' ')
            ++i;                        /* the space after the number */

        if (n + 5 >= room) {
            msg("too large");
            return 0;
        }
        if (prevlink != 0xFFFF) {       /* previous line links to this one */
            addr = 0x0801 + n;
            dst[prevlink] = (unsigned char)(addr & 0xFF);
            dst[prevlink + 1] = (unsigned char)(addr >> 8);
        }
        prevlink = n;
        dst[n++] = 0;                   /* link, patched when the next starts */
        dst[n++] = 0;
        dst[n++] = (unsigned char)(line & 0xFF);
        dst[n++] = (unsigned char)(line >> 8);

        quoted = 0;
        literal = 0;                    /* 1 = until ':' (DATA), 2 = to EOL (REM) */
        while (i < dl && (c = chat(i)) != CR_CH) {
            if (n + 2 >= room) {
                msg("too large");
                return 0;
            }
            if (c == '"') {
                quoted ^= 1;
            } else if (!quoted && !literal) {
                tok = match_keyword(i, dl, &klen);
                if (tok) {
                    dst[n++] = tok;
                    i += klen;
                    if (tok == TOK_REM)
                        literal = 2;
                    else if (tok == TOK_DATA)
                        literal = 1;
                    continue;
                }
            }
            if (literal == 1 && c == ':')
                literal = 0;            /* DATA ends at the statement break */
            dst[n++] = c;
            ++i;
        }
        dst[n++] = 0;                   /* end of line */
        if (i < dl)
            ++i;                        /* consume the CR */
    }

    if (prevlink != 0xFFFF) {           /* last line links to the terminator */
        addr = 0x0801 + n;
        dst[prevlink] = (unsigned char)(addr & 0xFF);
        dst[prevlink + 1] = (unsigned char)(addr >> 8);
    }
    if (n + 2 >= room) {
        msg("too large");
        return 0;
    }
    dst[n++] = 0;                       /* $0000 link: end of program */
    dst[n++] = 0;
    return n;
}

static char msgbuf[24];

static unsigned char save_file(void)
{
    unsigned int i, dl = doclen();
    unsigned char n;
    unsigned int blen = 0;
    unsigned char *stage = 0;

    if (fnlen == 0 && !prompt_name())
        return 0;

    /* A listing goes back out as a PROGRAM, not as its own source text.
       Tokenize into the gap -- the gap buffer's free middle is exactly the
       scratch space we need, and chat() never reads it, so the document stays
       readable while we build. Tokenized output is always smaller than the
       text it came from, so if the document fits, so does the program. */
    if (basic_mode) {
        stage = BUF + gs;
        blen = tokenize(stage, (unsigned int)(ge - gs));
        if (blen == 0)
            return 0;                   /* tokenize() said why */
    }
    n = build_iocmd(basic_mode ? ",p,w" : ",s,w", 1);
    STREG = 0;
    k_setlfs(8, 2);
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
    if (basic_mode) {
        k_chrout(0x01);                 /* PRG load address $0801 */
        k_chrout(0x08);
        for (i = 0; i < blen; ++i)
            k_chrout(stage[i]);
        dl = blen + 2;                  /* what the "wrote" message reports */
    } else {
        for (i = 0; i < dl; ++i)
            k_chrout(chat(i));
    }
    k_clrchn();
    k_close();
    if (STREG & 0x83) {
        msg("write error");
        return 0;
    }
    modified = 0;
    msgbuf[0] = 'w'; msgbuf[1] = 'r'; msgbuf[2] = 'o'; msgbuf[3] = 't';
    msgbuf[4] = 'e'; msgbuf[5] = ' ';
    print_u16(msgbuf + 6, dl);
    msg(msgbuf);
    return 1;
}


static void load_file(void)
{
    unsigned int raw = 0, i, link;
    unsigned char n, c, st;

    basic_mode = 0;
    /* Open by NAME ONLY, no ",s,r": the type suffix restricted this to SEQ, so
       a tokenized program could not be opened at all -- the drive reports the
       file as missing rather than as the wrong type. By name, the drive hands
       over whatever it is, and we decide below. */
    n = build_iocmd("", 0);
    STREG = 0;
    k_setlfs(8, 2);
    k_setnam((const char *)iocmd, n);
    if (k_open())
        return;
    if (k_chkin()) {
        k_close();
        return;
    }
    /* Stage the file high in the buffer; the listing expands down from 0. */
    for (;;) {
        c = k_chrin();
        st = STREG;
        if (st & 0x83)
            break;              /* device gone / timeout: drop c */
        if (st & 0x40) {        /* EOI = last byte. A 1541 clocks out a real   */
            if (c && raw < RAWMAX)  /* final byte; Meatloaf ends the stream with */
                BUF[RAWOFF + raw++] = c;  /* a synthetic $00 (no byte) -- storing */
            break;              /* it would show a trailing '?' (scrc($00)='?'). */
        }
        if (raw < RAWMAX)
            BUF[RAWOFF + raw++] = c;
    }
    k_clrchn();
    k_close();

    /* Is it a tokenized BASIC program? The load address must be $0801 AND the
       first line link must point forward past it -- the address alone would
       also match data that merely begins $01,$08. (A full chain walk is the
       stronger test, but this is the part that matters before we commit to
       expanding, and a bad guess only produces a garbled listing, never a
       crash: unknown bytes pass through as characters. That is what a real
       LIST does with an ML program carrying a BASIC loader, too.) */
    link = (raw >= 6) ? (BUF[RAWOFF + 2] | ((unsigned int)BUF[RAWOFF + 3] << 8)) : 0;
    if (raw >= 6 && BUF[RAWOFF] == 0x01 && BUF[RAWOFF + 1] == 0x08 && link > 0x0801) {
        basic_mode = 1;
        detokenize(BUF + RAWOFF, raw);
    } else {
        for (i = 0; i < raw; ++i)       /* plain text: copy down as-is */
            emit(BUF[RAWOFF + i]);
    }

    move_to(0);
    if (doclen() == 0)
        msg("new file");
    else if (basic_mode)
        msg("basic (read-only)");
}

/* --- key handling ----------------------------------------------------------- */
static void cursor_up_down(unsigned char down)
{
    unsigned int ls = line_start(gs);
    unsigned int col = gs - ls;
    unsigned int t, e;

    if (down) {
        e = line_end(gs);
        if (e >= doclen())
            return;
        t = e + 1;
    } else {
        if (ls == 0)
            return;
        t = line_start(ls - 1);
    }
    e = line_end(t);
    move_to(t + (col > e - t ? e - t : col));
}

void edit_main(void)
{
    unsigned char c, i;
    unsigned char light, had_msg, was_mod;

    /* fresh session state: a cached overlay re-runs with stale globals */
    gs = 0;
    ge = BUFSZ;
    top = 0;
    cliplen = 0;
    modified = 0;
    msg_hold = 0;
    chain = 0;
    literal_next = 0;
    build_sctab();
    fnlen = 0;
    if (BD_ARGC > 1) {
        char **argv = BD_ARGV;
        while (argv[1][fnlen] && fnlen < 16) {
            fname[fnlen] = argv[1][fnlen];
            ++fnlen;
        }
    }
    (void)i;
    if (fnlen)
        load_file();

    fill_color();               /* uniform color RAM before the first paint */
    render();
    for (;;) {
        c = k_getin();
        if (!c)
            continue;
        had_msg = msg_hold;
        msg_hold = 0;
        was_mod = modified;
        light = 0;
        if (c != 0x0B && c != 0x03)
            chain = 0;          /* any other key breaks a cut/copy chain */
        if (literal_next) {     /* ^V: take this key as text, whatever it is */
            literal_next = 0;
            insert_ch(c);
            modified = 1;
            ensure_visible();
            render();
            continue;
        }
        switch (c) {
        case 0x16:                          /* ^V insert the next key literally */
            /* PETSCII white is $05, which IS ^E -- the line-end binding eats
               it, so CTRL+2 could never reach the text. The same clash waits
               for every control code an editor binds: cursor down ($11), home
               ($13), clear ($93) and the rest are all legal inside a BASIC
               string. One escape key settles the whole class instead of
               rebinding keys one at a time. */
            literal_next = 1;
            msg("literal: next key");
            continue;           /* NOT return -- that is how ^X quits */

        case 0x18:                          /* ^X exit */
            if (!modified)
                goto out;
            msg("save modified buffer? (y/n)");
            render();
            for (;;) {
                c = k_getin();
                if (c == 'y') {
                    if (save_file())
                        goto out;
                    break;                  /* save failed: stay */
                }
                if (c == 'n')
                    goto out;
                if (c)
                    break;                  /* anything else: cancel */
            }
            msg_hold = 0;
            break;
        case 0x0F:                          /* ^O save */
            save_file();
            break;
        case 0x0B:                          /* ^K cut line */
            clip_line(1);
            break;
        case 0x03:                          /* ^C copy line */
            clip_line(0);
            break;
        case 0x15:                          /* ^U paste */
            paste();
            break;
        case 0x01:                          /* ^A line start */
        case K_HOME:
            move_to(line_start(gs));
            light = 1;
            break;
        case 0x05:                          /* ^E line end */
            move_to(line_end(gs));
            light = 1;
            break;
        case K_LEFT:
            if (gs)
                move_to(gs - 1);
            light = 1;
            break;
        case K_RIGHT:
            if (gs < doclen())
                move_to(gs + 1);
            light = 1;
            break;
        case K_UP:
            cursor_up_down(0);
            break;
        case K_DOWN:
            cursor_up_down(1);
            break;
        case K_DEL:
            if (gs) {
                if (chat(gs - 1) != CR_CH)
                    light = 1;              /* in-line delete */
                --gs;
                modified = 1;
            }
            break;
        case CR_CH:
            insert_ch(CR_CH);               /* structural: full redraw */
            break;
        default:
            /* Printable text, the PETSCII GRAPHICS set ($A0-$FF, C= + key),
               plus the colour codes (CTRL/C= 1-8).
               Those are control bytes, so they would otherwise be swallowed
               here -- and they are the only way to put a colour into a BASIC
               string. ($05 white is the exception: it collides with ^E and
               needs ^V, above.) */
            if ((c >= 0x20 && c <= 0x7E) || c >= 0xA0 || c == 0x05 ||
                c == 0x1C || c == 0x1E || c == 0x1F ||
                (c >= 0x81 && c <= 0x9F && c != 0x8D && c != 0x91 &&
                 c != 0x93 && c != 0x9D)) {
                insert_ch(c);
                light = 1;
            }
            break;
        }
        /* Light path: the op stayed on the cursor's line (verified by the
           line start matching the last full render), so nothing scrolled --
           repaint one row instead of the whole window. Crossing to another
           line, RETURN, cut/paste, and cursor up/down take the full path. */
        if (light && row_start(gs) == cur_ls) {
            if (had_msg)
                draw_help();
            render_line(modified != was_mod);
        } else {
            ensure_visible();
            render();
        }
    }
out:
    k_chrout(0x93);             /* clear the screen for the shell prompt */
}
