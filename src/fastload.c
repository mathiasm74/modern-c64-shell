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

/* Per-device capability cache, three-way since v0.2.40:
     0 = not probed
     1 = no fast path
     2 = FINGERPRINT drive (Meatloaf): checksums the upload, never runs it
     3 = EXECUTING drive (real 1541, Pi1541): runs what we M-W + M-E
   BSS, so a reboot re-probes.                                            */
static unsigned char epyx_cap[8];

#define CAP_NONE  1
#define CAP_PRINT 2
#define CAP_EXEC  3

/* The device the probe last confirmed is Meatloaf-class, or 0. Page 3, not BSS:
   the bank's BSS is wiped on every entry, and the one reader is the resident
   stock swap (launch.s), which pokes it into KLOAD's kl_dev. KLOAD fast-loads
   ONLY that device, because its fast path M-E's fingerprint filler that a real
   1541 would execute and hang on. reset.s zeroes it. */
#define KL_MEATDEV (*(unsigned char *)0x03A5)

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
            epyx_cap[i] = CAP_NONE;
        else if (buf[0] == 0 && buf[1] == 0)
            epyx_cap[i] = CAP_PRINT;    /* emulated RAM -> Meatloaf-class */
        else
            epyx_cap[i] = CAP_EXEC;     /* a real ROM vector -> real 6502 */
    }
    if (epyx_cap[i] == CAP_PRINT)
        KL_MEATDEV = fl_dev;
    else if (KL_MEATDEV == fl_dev)
        KL_MEATDEV = 0;
    return epyx_cap[i] == CAP_PRINT;
}

/* A drive that answers M-R with its real ROM vector runs a real 6502, so it can
   be given real code -- which is what src/drive1541.s is. Before that existed
   this answer was folded into "not capable", and every genuine 1541 fell back
   to stock speed. */
unsigned char fastload_drive_executes(void)
{
    fastload_epyx_capable();            /* probe if we have not yet */
    return epyx_cap[fl_dev - 8] == CAP_EXEC;
}

/* Start src/drive1541.s in the drive, in two stages.
   M-W is ~2.4 ms a byte, so uploading the 492-byte loader that way cost 1.5 s
   a load. Only the bootstrap (src/drive1541_boot.s, ~74 bytes) goes up by M-W
   and is M-E'd at $0400; it then clocks the loader in over the fast host->drive
   path -- the same epyx_send_byte a Meatloaf takes the filename on -- straight
   into $0500-$06FF, and jumps to it. The filename rides in that stream, patched
   into the loader's fixed header ($0503 = length, $0504 = 16 bytes of name), so
   it needs no M-W of its own either. */
#define FL_BOOT_BASE 0x0400
#define FL_DRV_CHUNK 32
#define FL_HDR_NLEN  3                  /* offsets into the loader's header */
#define FL_HDR_NAME  4
#define FL_HDR_END   (FL_HDR_NAME + 16)

unsigned char fastload_wait_drive(void);
extern unsigned char drive1541_code[];
extern unsigned int drive1541_size;
extern unsigned char drive1541_boot[];
extern unsigned int drive1541_boot_size;

/* No `I0` before any of this: it cost 1.36 s a load. The loader adopts the
   disk's ID itself when its first read reports a mismatch (read_sector in
   src/drive1541.s), which is what the cartridge does too. */
/* A SEEK job to the directory track, for buffer 0: track/sector at $06/$07,
   then the job code at $00, in that order so the controller never starts it
   with a stale track. */
static const unsigned char fl_seek_ts[2] = { 18, 0 };
static const unsigned char fl_seek_job = 0xB0;

unsigned char fastload_drive_install(const char *name, unsigned char namelen)
{
    unsigned char off, n, boot;

    /* Get the MOTOR going first. It only starts for a job, and spinning up
       costs ~1 s that used to begin after the whole upload, at the loader's
       first read. Posting a seek to track 18 through M-W lets the controller
       spin up and put the head where find_file will want it WHILE the
       bootstrap and loader go up. The loader's own reads use the same buffer
       and simply follow it. */
    fastload_mw(0x0006, fl_seek_ts, 2);
    fastload_mw(0x0000, &fl_seek_job, 1);
    if (iec_status() & (ST_NODEV | ST_TIMEOUT))
        return 1;

    /* The bootstrap is well under a page, so the offsets are bytes. */
    boot = (unsigned char)drive1541_boot_size;
    for (off = 0; off < boot; off += n) {
        n = boot - off;
        if (n > FL_DRV_CHUNK)
            n = FL_DRV_CHUNK;
        fastload_mw(FL_BOOT_BASE + off, drive1541_boot + off, n);
        if (iec_status() & (ST_NODEV | ST_TIMEOUT))
            return 1;
    }
    fastload_me(FL_BOOT_BASE);

    /* The bootstrap pulls CLK low when it is listening; begin answers with
       DATA low and waits for the release. */
    if (epyx_send_begin())
        return 1;
    /* The loader's fixed header, with the name patched in -- jmp, length,
       name padded with zeros to 16 -- then the rest straight out of ROM. The
       bootstrap knows the loader's exact length (assembled in), so there is
       no padding at the end. */
    if (namelen > 16)
        namelen = 16;
    epyx_send_mem(drive1541_code, FL_HDR_NLEN);
    epyx_send_byte(namelen);
    epyx_send_mem((const unsigned char *)name, namelen);
    for (off = namelen; off < 16; ++off)
        epyx_send_byte(0);
    epyx_send_mem(drive1541_code + FL_HDR_END, drive1541_size - FL_HDR_END);

    /* Releases CLK and HOLDS DATA low. The low is what the loader's first byte
       waits to see released: the M-E used to leave DATA high, and a drive
       waiting for "high" would have matched at once and transmitted before
       the host was looking. */
    epyx_send_end();

    /* Now wait for the LOADER to take the bus: it pulls CLK low ("not ready")
       as its first act, and the receiver's ready-wait is level-triggered -- so
       without this it would read garbage "bytes" before the drive had done
       anything. */
    if (fastload_wait_drive())
        return 1;
    return 0;
}

void fastload_epyx_mark_unsupported(void)
{
    epyx_cap[fl_dev - 8] = 1;
    if (KL_MEATDEV == fl_dev)
        KL_MEATDEV = 0;
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

