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
#define FNMB     ((unsigned char *)0x02D0)

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

static unsigned char scrc(unsigned char c)
{
    if (c < 0x20 || c > 0x7F)
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

static void draw_help(void)
{
    clear_row(SCREEN + 24 * COLS);
    put_str(SCREEN + 24 * COLS, "^x exit ^o save ^k cut ^c copy ^u paste");
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

/* Full redraw of the text window plus the cursor cell (inverted). */
static void render(void)
{
    unsigned int p = top, dl = doclen();
    unsigned char *row = SCREEN + COLS;     /* screen row 1 */
    unsigned char r, c;
    unsigned int cl;
    unsigned char crow = 255, ccol;

    /* cursor row/col relative to the window */
    cl = line_start(gs);
    ccol = (unsigned char)(gs - cl > 39 ? 39 : gs - cl);
    /* crow found while walking below (top is always a line start) */

    draw_title();
    for (r = 0; r < ROWS; ++r, row += COLS) {
        if (p == cl)
            crow = r;
        c = 0;
        while (p < dl && chat(p) != CR_CH) {
            if (c < COLS)
                row[c] = sctab[(chat(p) >= 0x20 && chat(p) <= 0x7F)
                               ? chat(p) - 0x20 : 0x1F];
            ++c;
            ++p;
        }
        while (c < COLS)
            row[c++] = 0x20;
        if (p < dl)
            ++p;                /* step past the CR */
        else if (p == cl && crow == 255)
            crow = r + 1;       /* cursor on the (empty) line past the end */
    }
    if (!msg_hold)
        draw_help();
    if (crow != 255 && crow < ROWS)
        SCREEN[(crow + 1) * COLS + ccol] |= 0x80;   /* show the cursor */
}

/* Keep the cursor's line inside the window. */
static void ensure_visible(void)
{
    unsigned int cl = line_start(gs);
    unsigned int p;
    unsigned char r;

    if (cl < top) {
        top = cl;
        return;
    }
    for (;;) {
        p = top;
        r = 0;
        while (p < cl) {
            if (chat(p) == CR_CH)
                ++r;
            ++p;
        }
        if (r < ROWS)
            return;
        top = line_end(top) + 1;            /* scroll down one line */
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

static char msgbuf[24];

static unsigned char save_file(void)
{
    unsigned int i, dl = doclen();
    unsigned char n;

    if (fnlen == 0 && !prompt_name())
        return 0;
    n = build_iocmd(",s,w", 1);
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
    for (i = 0; i < dl; ++i)
        k_chrout(chat(i));
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
    unsigned char n, c, st;

    n = build_iocmd(",s,r", 0);
    STREG = 0;
    k_setlfs(8, 2);
    k_setnam((const char *)iocmd, n);
    if (k_open())
        return;
    if (k_chkin()) {
        k_close();
        return;
    }
    for (;;) {
        c = k_chrin();
        st = STREG;
        if (st & 0x83)
            break;              /* device gone / timeout */
        if (gs < ge)
            BUF[gs++] = c;
        if (st & 0x40)
            break;              /* EOI: that was the last byte */
    }
    k_clrchn();
    k_close();
    move_to(0);
    if (doclen() == 0)
        msg("new file");
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

    /* fresh session state: a cached overlay re-runs with stale globals */
    gs = 0;
    ge = BUFSZ;
    top = 0;
    cliplen = 0;
    modified = 0;
    msg_hold = 0;
    chain = 0;
    build_sctab();
    fnlen = FNMB[0] <= 16 ? FNMB[0] : 16;
    for (i = 0; i < fnlen; ++i)
        fname[i] = FNMB[1 + i];
    if (fnlen)
        load_file();

    render();
    for (;;) {
        c = k_getin();
        if (!c)
            continue;
        msg_hold = 0;
        if (c != 0x0B && c != 0x03)
            chain = 0;          /* any other key breaks a cut/copy chain */
        switch (c) {
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
            break;
        case 0x05:                          /* ^E line end */
            move_to(line_end(gs));
            break;
        case K_LEFT:
            if (gs)
                move_to(gs - 1);
            break;
        case K_RIGHT:
            if (gs < doclen())
                move_to(gs + 1);
            break;
        case K_UP:
            cursor_up_down(0);
            break;
        case K_DOWN:
            cursor_up_down(1);
            break;
        case K_DEL:
            if (gs) {
                --gs;
                modified = 1;
            }
            break;
        case CR_CH:
            insert_ch(CR_CH);
            break;
        default:
            if (c >= 0x20 && c <= 0x7E)
                insert_ch(c);
            break;
        }
        ensure_visible();
        render();
    }
out:
    k_chrout(0x93);             /* clear the screen for the shell prompt */
}
