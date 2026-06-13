/* files.c - cat / less / cp / mv / rm as one multi-page tardis overlay.
 *
 * This whole file lives OUTSIDE the 16KB shell ROM: it's the "files" overlay
 * (cfg/overlay_files.cfg, entry via crt0_files.s) stored in the One ROM's
 * overlays flash set and fetched into $8800+ on first use. The resident side
 * (src/commands/fs.c) is just thin thunks that fill a mailbox and run it.
 *
 * Like every overlay it reaches the machine only through the fixed KERNAL
 * entry points -- no shell symbol is visible here -- so file I/O goes through
 * SETNAM/SETLFS/OPEN/CHKIN/CHKOUT/CHRIN/CHROUT/CLOSE/CLRCHN, exactly as the
 * edit overlay's load/save do.
 *
 * Mailbox from the thunk ($02D0):
 *   [0]   command: 0 cat, 1 less, 2 cp, 3 mv, 4 rm
 *   [1]   device (FA)
 *   [2]   arg1 length, [3..18] arg1 (<=16 chars)
 *   [19]  arg2 length, [20..35] arg2 (<=16 chars)
 *
 * State is all local (crt0 does not zero our BSS).
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

#define STREG    (*(volatile unsigned char *)0x90)
#define BUF      ((unsigned char *)0x0800)   /* cp staging, below the $8800 code */
#define BUFMAX   0x7800U                     /* $0800..$7FFF */

#define ST_EOI     0x40
#define ST_NODEV   0x80
#define ST_TIMEOUT 0x02

#define CR    0x0D
#define CLEAR 0x93
#define PAGE_LINES 22

static unsigned char dev;        /* MB[1], stashed at entry */

static void puts_raw(const char *s)
{
    while (*s)
        k_chrout(*s++);
}

static void crlf(void)
{
    k_chrout(CR);
}

/* Mailbox accessors -- absolute addresses (a base-pointer macro lets cc65
   reuse a loop-clobbered pointer register, mislanding a store/load). */
#define MB_CMD (*(unsigned char *)0x02D0)
#define MB_DEV (*(unsigned char *)0x02D1)
#define A1L    (*(unsigned char *)0x02D2)
#define A1     ((const char *)0x02D3)        /* 16 chars */
#define A2L    (*(unsigned char *)0x02E3)
#define A2     ((const char *)0x02E4)        /* 16 chars */

/* ---- cat (dump) / less (page) ------------------------------------------- */
static void pager(unsigned char paged)
{
    unsigned char b, last = CR, lines = 0, c;

    k_setnam(A1, A1L);
    k_setlfs(dev, 2);                   /* read data channel */
    k_open();
    if (STREG & ST_NODEV) {
        puts_raw("no device");
        crlf();
        return;
    }
    k_chkin();
    for (;;) {
        b = k_chrin();
        if (STREG & ST_TIMEOUT)
            break;
        k_chrout(b);
        last = b;
        if (paged && b == CR && ++lines >= PAGE_LINES) {
            puts_raw("-- more --");
            do { c = k_getin(); } while (c == 0);
            if (c == 'q')
                break;
            k_chrout(CLEAR);
            lines = 0;
            last = CR;
        }
        if (STREG & ST_EOI)
            break;
    }
    k_close();
    k_clrchn();
    if (STREG & ST_TIMEOUT) {
        puts_raw("read error");
        crlf();
    } else if (last != CR) {            /* leave the prompt on a fresh line */
        crlf();
    }
}

/* ---- print an unsigned int in decimal ----------------------------------- */
static void put_uint(unsigned int v)
{
    char d[5];
    unsigned char n = 0;

    do {
        d[n++] = '0' + (v % 10);
        v /= 10;
    } while (v);
    while (n)
        k_chrout(d[--n]);
}

/* ---- cp <src> <dst>: read src into BUF, write a new PRG dst -------------- */
static void copy(void)
{
    unsigned int len = 0, i;
    char dstname[24];
    unsigned char j, k;

    /* read src (channel 0 = load semantics: load address then data) */
    k_setnam(A1, A1L);
    k_setlfs(dev, 0);
    k_open();
    if (STREG & ST_NODEV) {
        puts_raw("no device");
        crlf();
        return;
    }
    k_chkin();
    for (;;) {
        if (len >= BUFMAX)              /* keep clear of the $8800 overlay code */
            break;
        BUF[len++] = k_chrin();
        if (STREG & (ST_EOI | ST_TIMEOUT))
            break;
    }
    k_close();
    k_clrchn();
    if (STREG & ST_TIMEOUT) {
        puts_raw("read error");
        crlf();
        return;
    }

    /* build "<dst>,p,w" */
    k = 0;
    for (j = 0; j < A2L && k < 16; ++j)
        dstname[k++] = A2[j];
    dstname[k++] = ',';
    dstname[k++] = 'p';
    dstname[k++] = ',';
    dstname[k++] = 'w';

    /* write it (the deferred-write CHROUT sends the last byte with EOI on
       CLRCHN, so CLOSE finalizes the file -- same as the edit overlay save) */
    k_setnam(dstname, k);
    k_setlfs(dev, 2);
    k_open();
    k_chkout();
    for (i = 0; i < len; ++i)
        k_chrout(BUF[i]);
    k_clrchn();
    k_close();

    puts_raw("copied ");
    put_uint(len);
    puts_raw(" bytes");
    crlf();
}

/* ---- mv / rm: a drive command-channel command (OPEN SA 15 sends it) ------ */
static void command_channel(const char *cmd, unsigned char len)
{
    k_setnam(cmd, len);
    k_setlfs(dev, 15);                  /* command channel */
    k_open();
    k_close();
    k_clrchn();
    if (STREG & ST_NODEV) {
        puts_raw("no device");
        crlf();
    }
}

/* rm <name> -> "s0:<name>" */
static void scratch(void)
{
    char c[20];
    unsigned char i = 0, j;

    c[i++] = 's'; c[i++] = '0'; c[i++] = ':';
    for (j = 0; j < A1L && i < sizeof(c); ++j)
        c[i++] = A1[j];
    command_channel(c, i);
}

/* mv <old> <new> -> "r0:<new>=<old>" (arg1 old, arg2 new) */
static void rename_file(void)
{
    char c[40];
    unsigned char i = 0, j;

    c[i++] = 'r'; c[i++] = '0'; c[i++] = ':';
    for (j = 0; j < A2L && i < 20; ++j)
        c[i++] = A2[j];
    c[i++] = '=';
    for (j = 0; j < A1L && i < sizeof(c); ++j)
        c[i++] = A1[j];
    command_channel(c, i);
}

void files_main(void)
{
    unsigned char cmd = MB_CMD;

    dev = MB_DEV;
    if (cmd == 0)
        pager(0);                       /* cat */
    else if (cmd == 1)
        pager(1);                       /* less */
    else if (cmd == 2)
        copy();
    else if (cmd == 3)
        rename_file();                  /* mv */
    else
        scratch();                      /* rm */
}
