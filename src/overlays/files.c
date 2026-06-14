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
 *   [0]   command: 0 cat, 1 less, 2 cp, 3 mv, 4 rm, 5 save, 6 status
 *   [1]   device (FA)
 *   [2]   arg1 length, [3..18] arg1 (<=16 chars)
 *   [19]  arg2 length, [20..35] arg2 (<=16 chars)
 *   For save (5): arg1 = name, and $02E4/$02E6 (the arg2 bytes) hold the
 *   start address and byte count as 16-bit words.
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
/* save (cmd 5) overloads the arg2 bytes as two 16-bit words instead of a
   string: the source start address and the byte count. */
#define SV_START (*(const unsigned int *)0x02E4)
#define SV_COUNT (*(const unsigned int *)0x02E6)

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

/* ---- save: write COUNT bytes from START to a new PRG <name> (cmd 5) ------ */
static void save_mem(void)
{
    char dstname[24];
    unsigned char j, k;
    unsigned int i, start = SV_START, count = SV_COUNT;
    const unsigned char *src = (const unsigned char *)start;

    /* build "<name>,p,w" */
    k = 0;
    for (j = 0; j < A1L && k < 16; ++j)
        dstname[k++] = A1[j];
    dstname[k++] = ','; dstname[k++] = 'p'; dstname[k++] = ','; dstname[k++] = 'w';

    k_setnam(dstname, k);
    k_setlfs(dev, 2);
    k_open();
    if (STREG & ST_NODEV) {
        puts_raw("no device");
        crlf();
        return;
    }
    /* PRG = 2-byte load address then the data. The deferred-write CHROUT sends
       the final byte with EOI on CLRCHN, so CLOSE finalizes the file. */
    k_chkout();
    k_chrout((unsigned char)(start & 0xff));
    k_chrout((unsigned char)(start >> 8));
    for (i = 0; i < count; ++i)
        k_chrout(src[i]);
    k_clrchn();
    k_close();

    puts_raw("saved ");
    put_uint(count);
    puts_raw(" bytes");
    crlf();
}

/* True if a 2-char numeric field is "00" (a zero track/sector/count). */
static unsigned char is_zero(const char *s)
{
    return s[0] == '0' && s[1] == '0' && s[2] == 0;
}

/* chkin + read the open channel 15 into buf, skipping the drive's own CR (some
   drives -- Meatloaf -- end on the last data byte with no CR, so we control the
   newline), then split "code,message,track,sector" into f[0..3] in place.
   Returns the 2-digit DOS code, or -1 on a read timeout. buf must be >= 64. */
static int read_status(char *buf, char **f)
{
    unsigned char n = 0, nf = 1, i, b;

    k_chkin();
    for (;;) {
        b = k_chrin();
        if (STREG & ST_TIMEOUT)
            break;
        if (b != CR && b != 0 && n < 63)
            buf[n++] = b;
        if (STREG & ST_EOI)
            break;
    }
    if (STREG & ST_TIMEOUT)
        return -1;
    buf[n] = 0;
    f[0] = buf; f[1] = ""; f[2] = ""; f[3] = "";
    for (i = 0; buf[i]; ++i) {
        if (buf[i] == ',' && nf < 4) {
            buf[i] = 0;
            f[nf++] = &buf[i + 1];
        }
    }
    if (!f[0][0])
        return 0;
    return (f[0][0] - '0') * 10 + (f[0][1] ? f[0][1] - '0' : 0);
}

/* ---- status: read + reformat the drive error channel (15) (cmd 6) -------- */
static void status_read(void)
{
    char buf[64];
    char *f[4];
    char *msg;
    int code;

    k_setnam("", 0);
    k_setlfs(dev, 15);                  /* command/error channel */
    k_open();
    if (STREG & ST_NODEV) {
        puts_raw("no device");
        crlf();
        return;
    }
    code = read_status(buf, f);
    k_close();
    k_clrchn();
    if (code < 0) {
        puts_raw("read error");
        crlf();
        return;
    }

    /* "code message", appending "@ track,sector" only on a real disk error. */
    msg = f[1];
    while (*msg == ' ')                 /* drop the ", OK" leading space */
        ++msg;
    puts_raw(f[0]);                     /* numeric DOS code */
    k_chrout(' ');
    puts_raw(msg);                      /* human-readable message */
    if (f[2][0] && !(is_zero(f[2]) && is_zero(f[3]))) {
        puts_raw(" @ ");
        puts_raw(f[2]);
        k_chrout(',');
        puts_raw(f[3]);
    }
    crlf();
}

/* ---- mv / rm: a drive command-channel command (OPEN SA 15 executes it) ----
   Sends the command, then reads the resulting DOS status and reports a failure
   as "<what>message"; success is silent. `scratch` marks rm, whose success is
   "01,FILES SCRATCHED,<count>" -- a non-zero code that's OK unless the count is
   0 (nothing matched -> "not found"); mv (scratch=0) is OK only on code 00. */
static void command_channel(const char *cmd, unsigned char len,
                            const char *what, unsigned char scratch)
{
    char buf[64];
    char *f[4];
    char *msg;
    int code;

    k_setnam(cmd, len);
    k_setlfs(dev, 15);                  /* command channel */
    k_open();
    if (STREG & ST_NODEV) {
        puts_raw("no device");
        crlf();
        return;
    }
    code = read_status(buf, f);         /* OPEN ran it; read the result */
    k_close();
    k_clrchn();
    if (code <= 0)                      /* 00 OK, or -1 read timeout: silent */
        return;
    if (scratch && code == 1) {         /* FILES SCRATCHED: count in field 2 */
        if (is_zero(f[2])) {            /* nothing matched */
            puts_raw(what);
            puts_raw("not found");
            crlf();
        }
        return;                         /* scratched >= 1: success, silent */
    }
    msg = f[1];
    while (*msg == ' ')
        ++msg;
    puts_raw(what);
    puts_raw(msg);
    crlf();
}

/* rm <name> -> "s0:<name>" */
static void scratch(void)
{
    char c[20];
    unsigned char i = 0, j;

    c[i++] = 's'; c[i++] = '0'; c[i++] = ':';
    for (j = 0; j < A1L && i < sizeof(c); ++j)
        c[i++] = A1[j];
    command_channel(c, i, "rm: ", 1);
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
    command_channel(c, i, "mv: ", 0);
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
    else if (cmd == 5)
        save_mem();
    else if (cmd == 6)
        status_read();
    else
        scratch();                      /* rm */
}
