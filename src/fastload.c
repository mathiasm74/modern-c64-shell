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

#define FA_DEFAULT 8        /* matches shell default; future: pass it in   */

/* Working buffer big enough for the longest frame we send:
 *   "M-W" + addr_lo + addr_hi + len + 34-byte body  = 40 bytes.            */
static unsigned char buf[40];

/* Everything here lives in the KERNAL ROM half (CODE2 / RODATA2), so the
 * cc65-emitted BASIC ROM doesn't grow as the loader does. The pragma-pair
 * is the same one fs.c uses for cmd_runstock / cmd_help.                  */
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

    iec_set_fa(FA_DEFAULT);
    iec_set_fnadr(buf);
    iec_set_fnlen(i);
    iec_command_raw();
}

void fastload_me(unsigned int addr)
{
    unsigned char i = fill_prefix('E', addr);

    iec_set_fa(FA_DEFAULT);
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

    iec_set_fa(FA_DEFAULT);
    iec_set_fnadr(buf);
    iec_set_fnlen(i);
    iec_command_raw();
    if (iec_status() & ST_NODEV)
        return;

    /* TALK the command channel; the drive places `len` response bytes
       there. Read them and UNTALK.                                        */
    iec_set_fa(FA_DEFAULT);
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

/* Self-test entry point for test_fastload.py.
 *
 * Writes a known pattern into the drive's free buffer space, reads it back
 * with M-R, and leaves a footprint at a fixed RAM address so the test can
 * grade the result without a serial channel back to Python:
 *
 *   $0340       = $AA when this function ran to completion (poisoned by
 *                 the test to $00 before invocation)
 *   $0341..$0348 = the 8 bytes that came back via M-R
 *   $0349       = ST after the round-trip (0 if no error)
 *
 * We use the page-3 KERNAL working area, well clear of the cc65 stack.    */
static const unsigned char selftest_pattern[8] = {
    0xAB, 0xCD, 0xEF, 0x42, 0x55, 0xAA, 0x00, 0xFF
};

void fastload_selftest(void)
{
    unsigned char readback[8];
    unsigned char i;

    fastload_mw(0x0500, selftest_pattern, 8);
    fastload_mr(0x0500, readback, 8);

    for (i = 0; i < 8; ++i)
        *(unsigned char *)(0x0341 + i) = readback[i];
    *(unsigned char *)0x0349 = iec_status();
    *(unsigned char *)0x0340 = 0xAA;
}

/* Upload the drive-side blob in 34-byte M-W chunks, then M-E its entry. */
#define FL_MW_CHUNK 34
void fastload_install(void)
{
    unsigned int remaining = fastload_drive_code_size;
    unsigned int src = 0;
    unsigned int dst = FASTLOAD_DRIVE_ENTRY;
    unsigned char this_chunk;

    while (remaining != 0) {
        this_chunk = (remaining > FL_MW_CHUNK) ? FL_MW_CHUNK
                                               : (unsigned char)remaining;
        fastload_mw(dst, fastload_drive_code + src, this_chunk);
        if (iec_status() & ST_NODEV)
            return;
        src += this_chunk;
        dst += this_chunk;
        remaining -= this_chunk;
    }
    fastload_me(FASTLOAD_DRIVE_ENTRY);
}

void fastload_selftest_me(void)
{
    unsigned char sentinel = 0;

    /* Poison the drive's sentinel cell first so a no-op M-E is detectable
       (the drive code's job is to write $42; we want to see that change). */
    fastload_mw(0x07FF, selftest_pattern, 1);   /* writes $AB at $07FF    */
    fastload_install();
    fastload_mr(0x07FF, &sentinel, 1);

    *(unsigned char *)0x0351 = sentinel;
    *(unsigned char *)0x0352 = iec_status();
    *(unsigned char *)0x0350 = 0xAA;
}

#pragma code-name (pop)
#pragma rodata-name (pop)

