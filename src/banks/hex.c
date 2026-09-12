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

#define SCREEN   ((unsigned char *)0x0400)
#define CRAM     ((unsigned char *)0xD800)
#define COLS     40
#define ROWS     23                     /* screen rows 1..23 hold the dump */
#define BPR      8                      /* bytes per row */
#define STREG    (*(unsigned char *)0x90)

/* The document. Starts where a loaded program would; stops short of the bank
   RAM window ($9D00), which is where our own stack and BSS live -- growing
   into it would overwrite the editor while it runs. */
#define BUF      ((unsigned char *)0x0800)
#define BUFMAX   0x9400U

/* argc/argv published by the resident dispatcher (bank_dispatch in fs.c). */
#define BD_ARGC  (*(unsigned char *)0x03A0)
#define BD_ARGV  (*(char ***)0x03A1)
#define MB_DEV   (*(unsigned char *)0x02D1)

#define CR_CH    0x0D
#define K_LEFT   0x9D
#define K_RIGHT  0x1D
#define K_UP     0x91
#define K_DOWN   0x11
#define K_HOME   0x13
#define CTRL_X   0x18
#define CTRL_O   0x0F
#define TAB      0x09

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
    clear_row(SCREEN + 24 * COLS);
    put_str(SCREEN + 24 * COLS, s);
    msg_hold = 1;
}

static void draw_help(void)
{
    clear_row(SCREEN + 24 * COLS);
    put_str(SCREEN + 24 * COLS, "^x exit ^o save tab pane  0-9a-f edit");
}

static void draw_title(void)
{
    unsigned char *t = SCREEN;
    unsigned char i;

    clear_row(t);
    put_str(t, "hex: ");
    for (i = 0; i < fnlen; ++i)
        t[5 + i] = svc_scr_display(fname[i]);
    put_str(t + 23, "at ");
    put_hex16(t + 26, pos);
    put_str(t + 31, "of ");
    put_hex16(t + 34, flen);
    if (modified)
        t[39] = svc_scr_display('*');
}

/* One dump row: ADDR then BPR bytes in hex, then the same bytes as PETSCII. */
static void render_row(unsigned char r, unsigned int off)
{
    unsigned char *row = SCREEN + (r + 1) * COLS;
    unsigned char i, b;

    clear_row(row);
    if (off >= flen && off != 0 && flen != 0)
        return;                         /* past the end: leave it blank */
    if (off > flen)
        return;
    put_hex16(row, off);
    for (i = 0; i < BPR; ++i) {
        if (off + i >= flen)
            break;
        b = BUF[off + i];
        row[5 + i * 3] = svc_scr_display(hexd((unsigned char)(b >> 4)));
        row[6 + i * 3] = svc_scr_display(hexd(b));
        row[30 + i] = svc_scr_display(b);
    }
}

/* Column of the cursor cell on its row, per pane. */
static unsigned char cursor_col(void)
{
    unsigned char i = (unsigned char)((pos - top) % BPR);

    if (pane)
        return (unsigned char)(30 + i);
    return (unsigned char)(5 + i * 3 + nib);
}

static void render(void)
{
    unsigned char r;
    unsigned int off = top;

    draw_title();
    for (r = 0; r < ROWS; ++r) {
        render_row(r, off);
        off += BPR;
    }
    if (!msg_hold)
        draw_help();
    /* cursor: the cell drawn in reverse, like the text editor's */
    r = (unsigned char)((pos - top) / BPR);
    if (r < ROWS)
        SCREEN[(r + 1) * COLS + cursor_col()] |= 0x80;
}

static void fill_color(void)
{
    unsigned int i;

    for (i = 0; i < 1000; ++i)
        CRAM[i] = 0x0E;                 /* light blue, like the shell's default */
}

/* Keep the cursor's row on screen. */
static void ensure_visible(void)
{
    unsigned int last;

    if (pos < top) {
        top = (pos / BPR) * BPR;
        return;
    }
    last = top + (unsigned int)ROWS * BPR;
    if (pos >= last)
        top = ((pos / BPR) - (ROWS - 1)) * BPR;
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
    unsigned char c, v, i;
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
    render();

    for (;;) {
        c = k_getin();
        if (!c)
            continue;
        msg_hold = 0;

        if (c == CTRL_X) {
            if (modified) {
                msg("discard changes? y/n");
                for (;;) {
                    v = k_getin();
                    if (v == 'y' || v == 'n')
                        break;
                }
                if (v == 'n') {
                    msg_hold = 0;
                    render();
                    continue;
                }
            }
            k_chrout(0x93);
            return;
        }
        if (c == CTRL_O) {
            if (fnlen)
                save_file();
            else
                msg("no file name");
            render();
            continue;
        }
        if (c == TAB) {
            pane ^= 1;
            nib = 0;
            render();
            continue;
        }
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
            if (nib == 0)
                BUF[pos] = (unsigned char)((BUF[pos] & 0x0F) | (v << 4));
            else
                BUF[pos] = (unsigned char)((BUF[pos] & 0xF0) | v);
            modified = 1;
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
            BUF[pos] = c;
            modified = 1;
            if (pos + 1 < flen)
                ++pos;
        }
        ensure_visible();
        render();
    }
    (void)i;
}
