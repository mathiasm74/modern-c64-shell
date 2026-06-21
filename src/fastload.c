/* fastload.c - Epyx-compatible fast loader: upload/exec/readback helpers.
 *
 * These build "M-W" / "M-E" / "M-R" command frames and ship them over the
 * stock IEC command channel. The fast 2-bit protocol that does the actual
 * data streaming after the install lives elsewhere (in assembly; not yet
 * written -- see PLAN.md Phase 7). Nothing here is timing-sensitive, so we
 * implement in C and let cc65 compile.
 *
 * Layout reference: 1541 reserves the lower 1KB ($0000-$03FF) for its
 * stock buffers and zero page; $0500-$07FF is free buffer space behind
 * buffers #1 and #2 and is what Epyx-style loaders use for the resident
 * fast-send routine.
 *
 * M-W / M-R bodies are at most 34 bytes (the 1541's command-channel
 * parse buffer limit). Callers that need to ship more must chunk
 * themselves -- a higher-level installer that wraps that is on the
 * Phase 7 to-do.
 */
#include "fastload.h"
#include "iec.h"

/* The device the fast-loader helpers target; set per command invocation
   (the shell's default_device) via fastload_set_device().               */
static unsigned char fl_dev = 8;

/* Working buffer big enough for the longest frame we send:
 *   "M-W" + addr_lo + addr_hi + len + 34-byte body  = 40 bytes.            */
static unsigned char buf[40];

/* Everything here lives in the KERNAL ROM half (CODE2 / RODATA2), so the
 * cc65-emitted BASIC ROM doesn't grow as the loader does. The pragma-pair
 * is the same one fs.c uses for cmd_exit / cmd_help.                      */
#pragma code-name (push, "CODE2")
#pragma rodata-name (push, "RODATA2")

/* Build the "M-W"/"M-E"/"M-R" prefix at buf[0..4]. Returns the next
   write index (5 for M-E, 5 for M-R sans length, 6 for M-W with length).
   Splitting this out keeps the three helpers readable.                    */
static unsigned char fill_prefix(char op, unsigned int addr)
{
    buf[0] = 'M';
    buf[1] = '-';
    buf[2] = op;
    buf[3] = (unsigned char)(addr & 0xff);
    buf[4] = (unsigned char)(addr >> 8);
    return 5;
}

void fastload_mw(unsigned int addr, const unsigned char *data,
                 unsigned char len)
{
    unsigned char i = fill_prefix('W', addr);
    unsigned char j;

    buf[i++] = len;
    for (j = 0; j < len; ++j)
        buf[i++] = data[j];

    iec_set_fa(fl_dev);
    iec_set_fnadr(buf);
    iec_set_fnlen(i);
    iec_command_raw();
}

void fastload_me(unsigned int addr)
{
    unsigned char i = fill_prefix('E', addr);

    iec_set_fa(fl_dev);
    iec_set_fnadr(buf);
    iec_set_fnlen(i);
    iec_command_raw();
}

void fastload_mr(unsigned int addr, unsigned char *dst, unsigned char len)
{
    unsigned char i = fill_prefix('R', addr);
    unsigned char j;

    /* Newer 1541 ROMs honor a body length here; older ROMs ignore it but
       still read fine since the command parse stops at the bus turnaround.
       Including it costs us one byte and helps with SD2IEC and friends.   */
    buf[i++] = len;

    iec_set_fa(fl_dev);
    iec_set_fnadr(buf);
    iec_set_fnlen(i);
    iec_command_raw();
    if (iec_status() & ST_NODEV)
        return;

    /* TALK the command channel; the drive places `len` response bytes
       there. Read them and UNTALK.                                        */
    iec_set_fa(fl_dev);
    iec_set_sa(15);
    iec_chkin();
    if (iec_status() & ST_NODEV) {
        iec_clrchn();
        return;
    }
    for (j = 0; j < len; ++j)
        dst[j] = iec_getbyte();
    iec_clrchn();
}

/* Clean-room Epyx V2/V3 fingerprint upload (see docs/FASTLOAD-FINGERPRINT.md).
 *
 * Meatloaf matches the Epyx FastLoad cartridge by three M-W chunks into the
 * 1541 stack page and an M-E $01A9; crucially it only sums each chunk's bytes
 * (IECFileDevice.cpp::checkMWcmd) and compares against $53/$A6/$8F -- it never
 * runs the uploaded code. So these 75 bytes are pure fingerprint bait: $EA
 * ("NOP") filler with a final byte per chunk chosen so the 8-bit additive sum
 * lands on Meatloaf's value. 24 * $EA = ...$F0, so the last byte is
 * (target - $F0) & $FF. (A real 1541 would EXECUTE this and would need genuine
 * Epyx drive bytes -- out of scope; the target is Meatloaf.)                */
#define EPYX_F 0xEA                     /* filler byte (24 per chunk)         */
const unsigned char fastload_epyx_upload[3 * FL_EPYX_CHUNK] = {
    /* chunk 1 -> $0180, 8-bit sum $53 */
    EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F,
    EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F,
    EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, 0x63,
    /* chunk 2 -> $0199, 8-bit sum $A6 */
    EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F,
    EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F,
    EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, 0xB6,
    /* chunk 3 -> $01B2, 8-bit sum $8F */
    EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F,
    EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F,
    EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, EPYX_F, 0x9F,
};

void fastload_set_device(unsigned char d)
{
    if (d >= 8 && d <= 15)
        fl_dev = d;
}

/* Per-device Epyx capability cache: 0 = not probed, 1 = no, 2 = yes.
   BSS, so a reboot re-probes.                                            */
static unsigned char epyx_cap[8];

unsigned char fastload_epyx_capable(void)
{
    unsigned char buf[2];
    unsigned char i = fl_dev - 8;

    if (epyx_cap[i] == 0) {
        /* Probe with a harmless M-R of the drive's reset vector ($FFFC).
           Every real-DOS drive (1541 family, JiffyDOS, Pi1541, ...) returns
           its ROM vector -- never $0000 -- and must NOT get the fingerprint
           install: it would EXECUTE our fake bytes (M-E) and crash. Meatloaf
           backs M-R with a small zero-initialized emulated RAM, so ROM
           addresses read as $00,$00: only that answer enables the fast path.
           A faking SD2IEC merely loses the speedup, never crashes.        */
        buf[0] = 0xEE;
        buf[1] = 0xEE;
        fastload_mr(0xFFFC, buf, 2);
        if (iec_status() & (ST_NODEV | ST_TIMEOUT))
            epyx_cap[i] = 1;
        else
            epyx_cap[i] = (buf[0] == 0 && buf[1] == 0) ? 2 : 1;
    }
    return epyx_cap[i] == 2;
}

void fastload_epyx_mark_unsupported(void)
{
    epyx_cap[fl_dev - 8] = 1;
}

void fastload_epyx_install(void)
{
    fastload_mw(FL_EPYX_MW1, fastload_epyx_upload, FL_EPYX_CHUNK);
    if (iec_status() & ST_NODEV)
        return;
    fastload_mw(FL_EPYX_MW2, fastload_epyx_upload + FL_EPYX_CHUNK, FL_EPYX_CHUNK);
    if (iec_status() & ST_NODEV)
        return;
    fastload_mw(FL_EPYX_MW3, fastload_epyx_upload + 2 * FL_EPYX_CHUNK,
                FL_EPYX_CHUNK);
    if (iec_status() & ST_NODEV)
        return;
    fastload_me(FL_EPYX_ME);
}

unsigned char fastload_epyx_send_header(const char *name, unsigned char namelen)
{
    unsigned char rc = epyx_send_begin();

    if (rc != 0)                        /* drive never signalled "ready"     */
        return rc;

    /* 256-byte op routine: Meatloaf only sums it (and discards the bytes), so
       255 x $00 + $86 = checksum $86 ("V2 load file"). Shipped by a tight ASM
       loop (epyx_send_op) -- it's all pre-transfer overhead before the first
       progress dot, so don't pay cc65's 16-bit per-byte loop for it.         */
    epyx_send_op(0x86);

    /* filename length, then the name in reverse (the drive reads it backwards
       into m_buffer[n-1..0], so the last character goes out first).          */
    epyx_send_byte(namelen);
    while (namelen != 0)
        epyx_send_byte((unsigned char)name[--namelen]);

    epyx_send_end();
    return 0;
}

/* 0-argument "$"-directory variant for OVERLAY callers (svc 12).
 *
 * An svc function may take at most ONE argument: an overlay and the resident
 * shell run on SEPARATE cc65 C stacks (overlay sp in ZP $40-$5F, resident sp in
 * $02-$1F), so the LAST argument -- passed in registers -- crosses the boundary
 * fine, but an earlier stack-passed argument does NOT: it's pushed on the
 * overlay's stack and read from the resident's, arriving as garbage. The 2-arg
 * fastload_epyx_send_header(name, namelen) therefore corrupted `name` when the
 * dir overlay called it through the svc table -- "$" arrived as 0xEE, so the
 * Meatloaf tried to cd into a nonexistent path and the listing failed. The dir
 * overlay always sends "$", so it calls this 0-arg wrapper instead; the call to
 * send_header below is resident->resident (one stack), so the name is correct.   */
unsigned char fastload_epyx_send_dir_header(void)
{
    return fastload_epyx_send_header("$", 1);
}

#pragma code-name (pop)
#pragma rodata-name (pop)

