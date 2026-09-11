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
 *   [0]   command: 0 cat, 1 less, 2 cp, 3 mv, 4 rm, 6 status, 7 cd,
 *         8 border, 9 bg, 10 text, 11 prompt, 12 peek, 13 poke,
 *         15 help, 16 device  (5 was save, 14 was echo; both removed)
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

/* TAB-completion name cache valid flag ($CE00; docs/TAB-COMPLETION.md). A
   directory-changing command clears it ONLY on success -- a failed cd/mv/rm/cp
   didn't change the directory, so the cached names (and the current path pwd
   reports) are still good and must survive the error. */
#define TC_OK  (*(unsigned char *)0xCE00)

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

    TC_OK = 0;                          /* a new file appeared -> stale cache */
    puts_raw("copied ");
    put_uint(len);
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
    if (code == 0) {                    /* 00 OK: success, silent */
        TC_OK = 0;                      /* directory changed -> stale cache */
        return;
    }
    if (code < 0)                       /* read timeout: no change, keep cache */
        return;
    if (scratch && code == 1) {         /* FILES SCRATCHED: count in field 2 */
        if (is_zero(f[2])) {            /* nothing matched: no change */
            puts_raw(what);
            puts_raw("not found");
            crlf();
        } else {
            TC_OK = 0;                  /* scratched >= 1: a file went away */
        }
        return;
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

/* cd <path> -> "cd:<path>", prebuilt by the resident thunk at $0340 with its
   length in A1L (paths can exceed the 16-char mailbox args). Reports a bad
   target as "cd: <message>"; success is silent. */
static void cd_path(void)
{
    command_channel((const char *)0x0340, A1L, "cd: ", 0);
}

/* ---- border / bg / text / prompt: appearance settings (cmd 8-11) --------- */
#define VIC_BORDER (*(unsigned char *)0xD020)
#define VIC_BG     (*(unsigned char *)0xD021)
#define COLOR_REG  (*(unsigned char *)0x0286)   /* KERNAL text color */

/* parse A1 as a small decimal value (0-15 after the caller masks). */
static unsigned char parse_dec(void)
{
    unsigned char v = 0, i;
    char c;

    for (i = 0; i < A1L; ++i) {
        c = A1[i];
        if (c < '0' || c > '9')
            break;
        v = v * 10 + (c - '0');
    }
    return v;
}

/* which: 0 border ($D020), 1 background ($D021), 2 text color ($0286). The
   no-value case (interactive color picker) is handled resident in config.c, so
   the overlay only ever gets a value here. */
static void set_color(unsigned char which)
{
    unsigned char val = parse_dec() & 0x0F;

    if (which == 0)
        VIC_BORDER = val;
    else if (which == 1)
        VIC_BG = val;
    else
        COLOR_REG = val;
}


/* ---- peek / poke / help: resident commands moved here (cmd 12,13,15) ------ */

/* parse an A1/A2 buffer (ptr + len, not NUL-terminated): hex if it starts with
   '$', else decimal. Same convention as the resident mem.c parser. */
static unsigned int parse_num16(const char *s, unsigned char len)
{
    unsigned int v = 0;
    unsigned char i;
    char c;

    if (len && s[0] == '$') {
        for (i = 1; i < len; ++i) {
            c = s[i];
            if (c >= '0' && c <= '9') v = (v << 4) | (c - '0');
            else if (c >= 'a' && c <= 'f') v = (v << 4) | (c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v = (v << 4) | (c - 'A' + 10);
            else break;
        }
    } else {
        for (i = 0; i < len; ++i) {
            c = s[i];
            if (c < '0' || c > '9') break;
            v = v * 10 + (c - '0');
        }
    }
    return v;
}

static void put_hnyb(unsigned char n)
{
    n &= 0x0F;
    k_chrout(n < 10 ? '0' + n : 'a' + (n - 10));
}
static void put_hex8(unsigned char b) { put_hnyb(b >> 4); put_hnyb(b); }
static void put_hex16(unsigned int v)
{
    put_hex8((unsigned char)(v >> 8));
    put_hex8((unsigned char)v);
}

/* peek <addr> [count]: one byte, or a count-byte hexdump (8/row, addr label). */
static void do_peek(void)
{
    unsigned int addr, count, i;
    unsigned char col;

    if (A1L == 0) {
        puts_raw("usage: peek <addr> [count] ($=hex)");
        crlf();
        return;
    }
    addr = parse_num16(A1, A1L);
    if (A2L == 0) {
        k_chrout('$');
        put_hex8(*(unsigned char *)addr);
        crlf();
        return;
    }
    count = parse_num16(A2, A2L);
    if (count == 0)
        count = 1;
    col = 0;
    for (i = 0; i < count; ++i) {
        if (col == 0) {
            k_chrout('$');
            put_hex16(addr + i);
            k_chrout(':');
        }
        k_chrout(' ');
        put_hex8(*(unsigned char *)(addr + i));
        if (++col == 8) {
            crlf();
            col = 0;
        }
    }
    if (col != 0)
        crlf();
}

/* poke <addr> <val>. */
static void do_poke(void)
{
    if (A1L == 0 || A2L == 0) {
        puts_raw("usage: poke <addr> <val> ($=hex)");
        crlf();
        return;
    }
    *(unsigned char *)parse_num16(A1, A1L) = (unsigned char)parse_num16(A2, A2L);
}

/* help: list every command in 3 column-major columns. The thunk passed the
   dispatch-table base ($02E4, struct command*) and entry count ($02E6).
   struct command = {const char *name; void (*fn)();} -> 4 bytes, name at +0. */
#define HELP_TABLE  (*(const char **)0x02E4)
#define HELP_COUNT  (*(const unsigned char *)0x02E6)
#define HELP_INDENT 2
#define HELP_COLS   3
#define HELP_COL_W  12
static void do_help(void)
{
    unsigned char count = HELP_COUNT;
    unsigned char rows = (count + HELP_COLS - 1) / HELP_COLS;
    unsigned char row, col, n, i;
    const char *base = HELP_TABLE;
    const char *name;

    puts_raw("Commands:");
    crlf();
    for (row = 0; row < rows; ++row) {
        for (n = 0; n < HELP_INDENT; ++n)
            k_chrout(' ');
        for (col = 0; col < HELP_COLS; ++col) {
            i = col * rows + row;
            if (i >= count)
                break;
            name = *(const char **)(base + i * 4);
            n = 0;
            while (name[n]) {
                k_chrout(name[n]);
                ++n;
            }
            while (n < HELP_COL_W) {
                k_chrout(' ');
                ++n;
            }
        }
        crlf();
    }
    /* The line-editor features nothing else advertises. Filename completion
       especially: the C64 has no TAB key, so it is bound to a bare CTRL tap
       (irq.s ctrl_tap), which nobody would guess. Kept to two short lines --
       the command list already fills most of the screen. */
    crlf();
    puts_raw("Tap CTRL to complete a file name.");
    crlf();
    puts_raw("Cursor up/down recalls commands.");
    crlf();
}

/* device <n> [name] (cmd 16): switch the default IEC unit. default_device and
   device_name[8][DEVNAME_ROW] STAY resident (read by every disk command + pwd); the
   thunk passes their addresses ($02F4 / $02F6) so we update them in place.
   Probe via KERNAL OPEN ("$" on the unit -> ST_NODEV if nothing answers). */
#define DEVADDR        (*(unsigned char **)0x02F4)   /* &default_device */
#define DNADDR         (*(char **)0x02F6)            /* &device_name[0][0] */
/* MUST match DEVNAME_ROW in src/commands/fs.c, which owns the array. It is a
   power of two so that the resident side's indexing is a shift instead of a
   16-bit multiply (which pulled cc65's mul runtime into the 16KB ROM); the
   stride here has to follow, or the two sides address different rows. */
#define DEVNAME_STRIDE 16

/* Fetch the drive's identity and derive a short prompt name into slot[].
   "UI" (warm reset, the quick one) re-arms the DOS power-on status whose
   73-message text names the drive: "CBM DOS V2.6 1541", "MEATLOAF CBM
   20260629.19", "SD2IEC V1.x", ... A known model number wins ("1541" etc.),
   else the first word, lowercased, capped at DEVNAME_MAX. slot[] is left
   empty on any failure -- the prompt then falls back to the unit number. */
static void derive_short_name(const char *t, char *slot)
{
    unsigned char i;

    slot[0] = 0;
    for (i = 0; t[i]; ++i) {            /* a model number anywhere in the text */
        if (t[i] == '1' && t[i + 1] == '5' && t[i + 3] == '1'
            && (t[i + 2] == '4' || t[i + 2] == '7' || t[i + 2] == '8')) {
            slot[0] = '1';
            slot[1] = '5';
            slot[2] = t[i + 2];
            slot[3] = '1';
            slot[4] = 0;
            return;
        }
    }
    for (i = 0; i < 10 && t[i] && t[i] != ' '; ++i)
        slot[i] = (t[i] >= 'A' && t[i] <= 'Z')  /* first word, lowercased */
                ? (char)(t[i] + 32) : t[i];
    slot[i] = 0;
}

/* Send "UI" to `unit` and read its 73-identity from channel 15 into buf/f;
   returns nonzero with f[1] = the identity text, 0 on any failure. */
static unsigned char read_identity(unsigned char unit, char *buf, char **f)
{
    unsigned char ok = 0;

    k_setnam("ui", 2);                  /* OPEN of ch15 executes the command */
    k_setlfs(unit, 15);
    k_open();
    if (!(STREG & ST_NODEV) && read_status(buf, f) >= 0 && f[1][0])
        ok = 1;
    k_close();
    k_clrchn();
    return ok;
}

static void fetch_identity(unsigned char unit, char *slot)
{
    char buf[64];
    char *f[4];

    slot[0] = 0;
    if (read_identity(unit, buf, f))
        derive_short_name(f[1], slot);
}

/* IEC probe mode (iec.s PROBEF): bounds the bus waits so a unit in an
   unknown state (absent, still powering up, sick: acks the LISTEN but stalls
   the EOI ack) times out instead of hanging the shell. Only for the
   probe/identify paths -- never normal transfers (a busy drive would be
   falsely dropped). */
#define PROBE (*(unsigned char *)0x02BC)

static unsigned char device_present_ov(unsigned char dev)
{
    unsigned char absent;

    k_setnam("$", 1);
    k_setlfs(dev, 0);
    k_open();
    absent = STREG & ST_NODEV;
    k_close();                          /* release the channel (abort if absent) */
    k_clrchn();
    return absent ? 0 : 1;
}

static void do_device(void)
{
    unsigned char dev, i, present;
    char *slot;

    if (A1L == 0) {
        puts_raw("usage: device <n> [name]");
        crlf();
        return;
    }
    dev = (unsigned char)parse_num16(A1, A1L);
    PROBE = 1;                          /* bounded: a sick drive can't hang us */
    present = device_present_ov(dev);
    PROBE = 0;
    if (!present) {                     /* don't switch to a unit that isn't there */
        puts_raw("device ");
        put_uint(dev);
        puts_raw(" not present");
        crlf();
        return;
    }
    *DEVADDR = dev;                     /* default_device = dev */
    if (A2L > 0 && dev >= 8 && dev <= 15) {
        slot = DNADDR + (dev - 8) * DEVNAME_STRIDE;
        for (i = 0; i < A2L && i < 10; ++i)
            slot[i] = A2[i];
        slot[i] = 0;
    } else if (dev >= 8 && dev <= 15) {
        slot = DNADDR + (dev - 8) * DEVNAME_STRIDE;
        if (!slot[0]) {                 /* nothing given or remembered: ask the
                                           drive who it is (shown in the prompt) */
            PROBE = 1;                  /* bounded; a timeout just leaves the
                                           slot empty (prompt shows the number) */
            fetch_identity(dev, slot);
            PROBE = 0;
        }
    }
    puts_raw("device ");
    put_uint(dev);
    if (dev >= 8 && dev <= 15) {
        slot = DNADDR + (dev - 8) * DEVNAME_STRIDE;
        if (slot[0]) {
            k_chrout(' ');
            puts_raw(slot);
        }
    }
    crlf();
}

/* devices (cmd 18): scan units 8-15, print each present unit's identity
   ("UI" + channel-15 73-message), and fill any empty name slot on the way
   (so a later `device <n>` -- and the prompt -- get the name for free). */
static void do_devices(void)
{
    char buf[64];
    char *f[4];
    char *slot;
    unsigned char u, found = 0, dots = 0;

    PROBE = 1;
    for (u = 8; u <= 15; ++u) {
        k_chrout('.');                  /* progress: one dot per unit probed */
        ++dots;
        if (read_identity(u, buf, f)) {
            while (dots) {              /* blank the dots (DEL erases + steps
                                           left), then the entry takes the line */
                k_chrout(0x14);
                --dots;
            }
            put_uint(u);
            puts_raw(": ");
            puts_raw(f[1]);
            crlf();
            slot = DNADDR + (u - 8) * DEVNAME_STRIDE;
            if (!slot[0])
                derive_short_name(f[1], slot);
            found = 1;
        }
    }
    PROBE = 0;
    while (dots) {                      /* wipe any trailing dots */
        k_chrout(0x14);
        --dots;
    }
    if (!found) {
        puts_raw("no devices found");
        crlf();
    }
}

/* quiet identify (cmd 17): boot-time fill of the current unit's name slot so
   the first prompt already reads "8: meatloaf>". Prints nothing; probe mode
   so a missing/booting drive can't wedge the boot (the AUTOEXEC hazard). */
static void identify_quiet(void)
{
    char *slot;

    if (dev < 8 || dev > 15)
        return;
    slot = DNADDR + (dev - 8) * DEVNAME_STRIDE;
    if (slot[0])
        return;
    PROBE = 1;
    fetch_identity(dev, slot);
    PROBE = 0;
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
    else if (cmd == 6)
        status_read();
    else if (cmd == 7)
        cd_path();
    else if (cmd == 8 || cmd == 9 || cmd == 10)
        set_color(cmd - 8);             /* border / bg / text */
    else if (cmd == 12)
        do_peek();
    else if (cmd == 13)
        do_poke();
    else if (cmd == 15)
        do_help();
    else if (cmd == 16)
        do_device();
    else if (cmd == 17)
        identify_quiet();
    else if (cmd == 18)
        do_devices();
    else
        scratch();                      /* rm */
}
