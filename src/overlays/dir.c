/* dir.c - dir / ls / pwd as one multi-page tardis overlay.
 *
 * Lives OUTSIDE the 16KB ROM (the "dir" overlay, cfg/overlay_dir.cfg, entry via
 * crt0_dir.s), fetched into $8800 on use. Unlike the files overlay, the
 * directory commands need the lower-level IEC bus and the badline-paced Epyx
 * fast receiver, which aren't KERNAL entry points -- so the overlay reaches
 * them through the shell-services jump table (svc.h / src/svc.s) at $FF80.
 * Output goes through k_chrout; the device number and remembered name come
 * from the resident thunk's mailbox.
 *
 * Mailbox from the thunk ($02D0): [0] command (0 dir, 1 ls, 2 pwd), [1] device,
 * [2] device-name length, [3..] device-name. State is all static (set before
 * use; crt0 does not zero our BSS).
 */
#include "svc.h"

unsigned char __fastcall__ k_chrout(unsigned char c);
unsigned char k_getin(void);            /* crt0_dir.s: GETIN ($FFE4) */

#define ST_EOI     0x40
#define ST_NODEV   0x80
#define ST_TIMEOUT 0x02
#define CR         0x0D
#define CLEAR      0x93
#define PAGE_LINES 24          /* 24 lines + the "-- more --" row fill the 25-row screen */
#define COL_WIDTH  20                /* ls: two name columns across the 40 cols */
#define TEXT_COLOR (*(unsigned char *)0x0286)
#define SHFLAG     (*(volatile unsigned char *)0x028D)  /* bit 2 = CTRL held */

#define MB_CMD  (*(unsigned char *)0x02D0)       /* 0 dir, 1 ls, 2 pwd */
#define MB_DEV  (*(unsigned char *)0x02D1)
#define MB_NLEN (*(unsigned char *)0x02D2)
#define MB_NAME ((const char *)0x02D3)

static char dir_buf[42];

/* --- TAB-completion name cache ($CE00; docs/TAB-COMPLETION.md) --------------
 * Filled as a side effect of drawing ls/dir ("the shell completes what it
 * last saw"); readline completes from it. Fixed page, free since the
 * single-page overlay loader was removed: [0] valid flag, [1] count, [2..]
 * packed [len][chars] entries, uppercase PETSCII as the drive sent them.
 * The fs.c thunks of directory-changing commands clear the flag. */
#define TC_OK    (*(unsigned char *)0xCE00)
#define TC_COUNT (*(unsigned char *)0xCE01)
#define TC_BASE  ((unsigned char *)0xCE02)
#define TC_MAX   509                    /* two pages, $CE02-$CFFF: ~40 names.
                                           $CF00 doubles as the run stub's
                                           home; launch_stock_program clears
                                           the valid flag before planting. */

static unsigned int tc_w;               /* write offset into TC_BASE */

static char up(char c);                 /* defined below (type-token folding) */

static void cache_reset(void)
{
    TC_OK = 0;
    TC_COUNT = 0;
    tc_w = 0;
}

/* Append dir_buf's quoted entry name to the cache. Ignores lines without a
 * quoted name (the BLOCKS FREE trailer), Meatloaf NFO pseudo-entries, and
 * anything that doesn't fit the remaining page (silent cap). */
static void cache_name(void)
{
    unsigned char i, q2, t, n;

    for (i = 0; dir_buf[i] && dir_buf[i] != '"'; ++i)
        ;
    if (dir_buf[i] != '"')
        return;
    ++i;
    for (q2 = i; dir_buf[q2] && dir_buf[q2] != '"'; ++q2)
        ;
    if (dir_buf[q2] != '"')
        return;
    for (t = q2 + 1; dir_buf[t] == ' '; ++t)
        ;
    if (dir_buf[t] == '*')
        ++t;
    if (up(dir_buf[t]) == 'N' && up(dir_buf[t + 1]) == 'F')
        return;                         /* NFO info line, not a file */
    n = q2 - i;
    if (n == 0 || n > 16 || tc_w + n >= TC_MAX || TC_COUNT == 255)
        return;
    TC_BASE[tc_w++] = n;
    while (i < q2)
        TC_BASE[tc_w++] = (unsigned char)up(dir_buf[i++]);
                                        /* fold to uppercase: network folders
                                           (Meatloaf) list lowercase-PETSCII
                                           ($C1-$DA) names that the matcher's
                                           typed-input fold would never hit */
    ++TC_COUNT;
}

/* A clean end of listing validates the cache (a read error leaves it off). */
static void cache_done(void)
{
    if (!(svc_iec_status() & (ST_TIMEOUT | 0x80)))
        TC_OK = 1;
}
static unsigned char dir_fast, fdir_left, fdir_eof;

/* The Epyx fast path is a TIMED transfer the drive aborts if we stall (the
   Meatloaf times out and drops back to its root), so it can't pause for
   pagination. To use it for ls/dir anyway, slurp the whole listing into RAM in
   one un-paused fast read, then page over RAM. The buffer is user RAM just above
   the screen; a listing longer than DBUF_MAX is truncated (the rest is drained
   from the drive but not shown). Standard IEC has no timeout, so it keeps the
   old un-buffered incremental path (no $0800 clobber). */
#define DBUF      ((unsigned char *)0x0800)
#define DBUF_MAX  0x4000                        /* 16 KB ~ 500+ lines */
static unsigned int dbuf_len, dbuf_pos, dbuf_w; /* replay len/pos, slurp write idx */
static unsigned char dir_buffered;

static void puts_raw(const char *s)
{
    while (*s)
        k_chrout(*s++);
}

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

/* --- directory byte source: RAM replay, fast (Epyx blocks), or standard IEC - */
static unsigned char dir_getbyte(void)
{
    unsigned char b;

    if (dir_buffered)
        return (dbuf_pos < dbuf_len) ? DBUF[dbuf_pos++] : 0;
    if (dir_fast) {
        while (fdir_left == 0) {
            if (fdir_eof || svc_epyx_wait_ready() != 0) {
                fdir_eof = 1;
                return 0;
            }
            fdir_left = svc_epyx_recv_byte();
            if (fdir_left == 0) {
                fdir_eof = 1;
                return 0;
            }
        }
        --fdir_left;
        b = svc_epyx_recv_byte();
        if (dbuf_w < DBUF_MAX)
            DBUF[dbuf_w++] = b;         /* buffer each byte for a possible paged replay */
        return b;
    }
    return svc_iec_getbyte();
}

static unsigned char dir_ended(void)
{
    if (dir_buffered)
        return (dbuf_pos >= dbuf_len) ? 1 : 0;
    if (dir_fast)
        return fdir_eof;
    return (svc_iec_status() & (ST_EOI | ST_TIMEOUT)) ? 1 : 0;
}

static unsigned char dir_begin(unsigned char allow_fast)
{
    dir_fast = 0;
    fdir_left = 0;
    fdir_eof = 0;

    svc_fastload_set_device(MB_DEV);
    if (allow_fast && svc_fastload_epyx_capable()) {
        svc_fastload_epyx_install();
        if (!(svc_iec_status() & ST_NODEV)) {
            if (svc_fastload_epyx_send_dir_header() == 0) {
                dir_fast = 1;
                dir_getbyte();              /* load address (2 bytes) */
                dir_getbyte();
                return 1;
            }
            svc_fastload_epyx_mark_unsupported();
        }
    }

    svc_iec_set_fa(MB_DEV);
    svc_iec_set_sa(0);
    svc_iec_setname("$");
    svc_iec_open();
    if (svc_iec_status() & ST_NODEV) {
        puts_raw("device ");
        put_uint(MB_DEV);
        puts_raw(" not present");
        k_chrout(CR);
        return 0;
    }
    svc_iec_chkin();
    svc_iec_getbyte();
    svc_iec_getbyte();
    return 1;
}

static unsigned char dir_line(unsigned int *blocks)
{
    unsigned char lo, hi, b, n;

    lo = dir_getbyte();
    if (dir_ended())
        return 0;
    hi = dir_getbyte();
    if (lo == 0 && hi == 0)
        return 0;

    lo = dir_getbyte();
    hi = dir_getbyte();
    *blocks = lo | ((unsigned int)hi << 8);

    n = 0;
    for (;;) {
        b = dir_getbyte();
        if (b == 0 || dir_ended())
            break;
        if (n < sizeof(dir_buf) - 1)
            dir_buf[n++] = b;
    }
    dir_buf[n] = 0;
    return 1;
}

static void dir_end(void)
{
    if (dir_fast) {
        while (!fdir_eof)               /* drain to EOF so the bus is left idle */
            dir_getbyte();
        dir_fast = 0;
        return;
    }
    svc_iec_close();
    svc_iec_clrchn();
    if (svc_iec_status() & ST_TIMEOUT) {
        puts_raw("read error");
        k_chrout(CR);
    }
}

/* dir_open / finish_slurp / dir_close - drive the listing for a paged display.
   The Epyx fast path is a timed transfer the Meatloaf aborts if we stall, so it
   can't pause mid-stream. To page it AND show the first files promptly, we stream
   it incrementally -- dir_getbyte hands each byte to dir_line for display AND
   buffers it into RAM -- and only when pagination is about to actually PAUSE do
   we drain the rest of the transfer into RAM (finish_slurp) and replay the
   remaining lines from there. A standard-IEC drive has no timeout, so it streams
   incrementally with no buffering (the old path, no $0800 clobber). */
static unsigned char dir_open(void)
{
    dir_buffered = 0;
    dbuf_w = 0;
    if (!dir_begin(1))                      /* fast if capable; reads 2 load-addr bytes */
        return 0;
    dbuf_w = 0;                             /* drop the load-addr bytes; buffer lines from 0 */
    return 1;
}

/* About to pause a fast (timed) transfer for "-- more --": the drive would time
   out, so first read everything still pending into RAM (no pause), then have
   dir_line replay from where the on-screen lines left off. */
static void finish_slurp(void)
{
    dbuf_pos = dbuf_w;                      /* page 2 starts where the shown lines ended */
    while (!fdir_eof)
        dir_getbyte();                      /* fast: reads + buffers, to EOF */
    dir_end();                              /* close the fast transfer (clears dir_fast) */
    dbuf_len = dbuf_w;
    dir_buffered = 1;                       /* dir_line now replays from RAM */
}

static void dir_close(void)
{
    if (!dir_buffered)                      /* fast free-scroll or standard: drive still open */
        dir_end();
}

/* Page the listing like `less`. Pressing CTRL at ANY point during the listing
   arms pagination (a sticky `*paged` flag): from then on, every PAGE_LINES
   lines it prints "-- more --" and waits for a key (q quits, any other clears
   the screen and continues). If CTRL is never pressed the listing just scrolls
   past. On quit it emits a CR so the shell prompt lands at the start of a line.
   Returns 1 on quit. The pause never stalls the drive: a standard listing is
   per-byte handshaked with no timeout (the drive just blocks); a fast (Epyx)
   listing is a timed transfer the Meatloaf would abort -- so if one is still
   live when we're about to pause, finish_slurp drains the rest into RAM first
   and the rest of the listing replays from there. Either way the pause is safe. */
static unsigned char paginate(unsigned char *lines, unsigned char *paged)
{
    unsigned char c;

    if (SHFLAG & 0x04) {                /* CTRL pressed at any time arms paging */
        *paged = 1;
        /* The pager just consumed CTRL as a modifier: spoil the CTRL-tap
           (irq.s ctrl_tap, $028E: 2 = spoiled) so releasing the key doesn't
           emit TAB -- which the "-- more --" key-wait would otherwise read
           as press-any-key and flip the page immediately. */
        *(volatile unsigned char *)0x028E = 2;
    }
    if (++(*lines) < PAGE_LINES)
        return 0;
    *lines = 0;
    if (!*paged)                        /* never armed -> free scroll, no pause */
        return 0;
    if (dir_fast)                       /* fast transfer still live -> drain it to RAM */
        finish_slurp();                 /* so the pause below can't abort the drive */
    puts_raw("-- more --");
    do {
        c = k_getin();
    } while (c == 0);
    if (c == 'q') {
        k_chrout(CR);                   /* put the prompt at the start of a line */
        return 1;
    }
    k_chrout(CLEAR);
    return 0;
}

/* fold one type-token char to uppercase (handles lowercase and shifted PETSCII) */
static char up(char c)
{
    if (c >= 'a' && c <= 'z')
        c -= 0x20;
    if ((unsigned char)c >= 0xC1 && (unsigned char)c <= 0xDA)
        c -= 0x80;
    return c;
}

/* Color a directory entry by its CBM type token (e.g. "PRG", "DIR"). The
   navigable kinds -- DIR and URL, both cd-able on a Meatloaf -- share a color
   (yellow); DEL (a deleted slot) is greyed even though it also starts with 'D',
   so the second char disambiguates DIR vs DEL. */
static unsigned char type_color(const char *type)
{
    char a = up(type[0]);
    char b = up(type[1]);

    switch (a) {
    case 'P': return 0x0D;                          /* PRG  light green */
    case 'S': return 0x03;                          /* SEQ  cyan        */
    case 'R': return 0x0A;                          /* REL  light red   */
    case 'U': return 0x07;                          /* USR / URL yellow */
    case 'D': return (b == 'I' || (b >= '0' && b <= '9'))
                     ? 0x07 : 0x0C;     /* DIR + disk images (D64/D71/D81...,
                                           all cd-able) yellow, DEL grey */
    default:  return 0x00;
    }
}

static void do_dir(void)
{
    unsigned int blocks;
    unsigned char lines = 0, paged = 0, first = 1;

    if (!dir_open())                    /* fast->slurp to RAM, else standard IEC */
        return;
    cache_reset();
    while (dir_line(&blocks)) {
        if (first)
            first = 0;                  /* header: don't cache the disk title */
        else
            cache_name();
        put_uint(blocks);
        k_chrout(' ');
        puts_raw(dir_buf);
        k_chrout(CR);
        if (paginate(&lines, &paged))
            break;
    }
    dir_close();
    cache_done();
}

static void do_ls(void)
{
    unsigned int blocks;
    unsigned char i, q2, t, color, saved, first, lines = 0, paged = 0;
    unsigned char col = 0, n;

    if (!dir_open())                    /* fast->slurp to RAM, else standard IEC */
        return;
    saved = TEXT_COLOR;
    first = 1;
    cache_reset();
    while (dir_line(&blocks)) {
        if (first) {
            first = 0;
            continue;
        }
        cache_name();
        for (i = 0; dir_buf[i] && dir_buf[i] != '"'; ++i)
            ;
        if (dir_buf[i] != '"')
            continue;
        ++i;
        for (q2 = i; dir_buf[q2] && dir_buf[q2] != '"'; ++q2)
            ;
        if (dir_buf[q2] != '"')
            continue;
        for (t = q2 + 1; dir_buf[t] == ' '; ++t)
            ;
        if (dir_buf[t] == '*')
            ++t;
        if (up(dir_buf[t]) == 'N' && up(dir_buf[t + 1]) == 'F')
            continue;                   /* skip Meatloaf NFO info lines (dir keeps them) */
        color = type_color(&dir_buf[t]);
        TEXT_COLOR = color ? color : saved;
        n = 0;
        while (i < q2) {                /* print the name, counting its width */
            k_chrout(dir_buf[i++]);
            ++n;
        }
        TEXT_COLOR = saved;             /* default color for the gap / CR */
        if (col == 0) {                 /* left column: pad out to the right one */
            while (n < COL_WIDTH) {
                k_chrout(' ');
                ++n;
            }
            col = 1;
        } else {                        /* right column: end the row, then page */
            k_chrout(CR);
            col = 0;
            if (paginate(&lines, &paged))
                break;
        }
    }
    if (col == 1)                       /* dangling left-column name -> end its row */
        k_chrout(CR);
    TEXT_COLOR = saved;
    dir_close();
    cache_done();
}

static void do_pwd(void)
{
    unsigned int blocks;
    unsigned char i, q0, q1, j;
    unsigned char any = 0, first = 1;

    if (!dir_begin(0))
        return;

    if (dir_line(&blocks)) {            /* header line: device, name, disk title */
        put_uint(MB_DEV);
        if (MB_NLEN) {
            k_chrout(' ');
            for (j = 0; j < MB_NLEN; ++j)
                k_chrout(MB_NAME[j]);
        }
        puts_raw(": ");
        for (i = 0; dir_buf[i] && dir_buf[i] != '"'; ++i)
            ;
        if (dir_buf[i] == '"') {
            ++i;
            while (dir_buf[i] && dir_buf[i] != '"')
                k_chrout(dir_buf[i++]);
        }
        k_chrout(CR);
    }

    while (dir_line(&blocks)) {         /* NFO header lines -> the path */
        for (i = 0; dir_buf[i] && dir_buf[i] != '"'; ++i)
            ;
        if (dir_buf[i] != '"')
            break;
        q0 = ++i;
        while (dir_buf[i] && dir_buf[i] != '"')
            ++i;
        q1 = i;
        while (q1 > q0 && dir_buf[q1 - 1] == ' ')
            --q1;
        if (q1 == q0)
            continue;
        if (dir_buf[q0] == '[') {
            first = 0;
            continue;
        }
        if (dir_buf[q0] == '-')
            break;
        if (first)
            break;
        for (i = q0; i < q1; ++i)
            k_chrout(dir_buf[i]);
        any = 1;
    }
    if (any)
        k_chrout(CR);
    dir_end();
}

void dir_main(void)
{
    unsigned char cmd = MB_CMD;

    if (cmd == 0)
        do_dir();
    else if (cmd == 1)
        do_ls();
    else
        do_pwd();
}
