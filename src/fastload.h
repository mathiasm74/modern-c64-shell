/* fastload.h - Epyx-compatible fast loader (Phase 7).
 *
 * The fast loader operates in two phases. First it installs a small 6502
 * routine into the 1541's free buffer space ($0500-$07FF) via standard CBM
 * DOS M-W (memory-write) commands on the command channel, then M-E
 * (memory-execute) to start it. The upload itself goes over stock-speed
 * IEC -- only the data-streaming phase after the install is fast (a 2-bit
 * timed protocol on CLK/DATA via $DD00 bits 6/7).
 *
 * This header exposes the building blocks. Higher-level helpers (file open
 * through the fast path, sector receive, etc.) will sit on top of these.
 *
 * All entry points target the current iec_*_fa / default device. The
 * helpers do NOT mask IRQs themselves -- the underlying iec layer does.
 */
#ifndef FASTLOAD_H
#define FASTLOAD_H

/* Write `len` bytes from `data` into drive memory starting at `addr`.
 *
 * Sends a single "M-W"+addr_lo+addr_hi+len+body frame on the command
 * channel (channel 15). The 1541's M-W parser caps the body at 34 bytes
 * per command; callers must chunk larger uploads themselves (or use the
 * helper that does it for them, once that exists). Sets ST_NODEV if the
 * drive doesn't answer.
 */
void fastload_mw(unsigned int addr, const unsigned char *data,
                 unsigned char len);

/* Read `len` bytes from drive memory starting at `addr` into `dst`.
 *
 * Sends a "M-R"+addr_lo+addr_hi+len frame on the command channel, then
 * TALKs the drive, reads the body via the standard ACPTR loop, and
 * UNTALKs. Caps at the drive's command-channel buffer size (34 bytes per
 * call, same as M-W). Sets ST_NODEV on no-device.
 *
 * Use for round-tripping known bytes through drive RAM during early
 * bring-up: M-W a sentinel, M-R it back, expect a match.
 */
void fastload_mr(unsigned int addr, unsigned char *dst, unsigned char len);

/* Execute drive code at `addr` (M-E).
 *
 * Returns immediately after sending the command -- the drive starts
 * running but hasn't necessarily produced any observable side effect by
 * the time this returns. Sets ST_NODEV on no-device.
 */
void fastload_me(unsigned int addr);

/* Drive-side image embedded in our ROM (see src/fastload_blob.s and
 * src/fastload_drive.s). fastload_install() ships it to the drive.        */
extern const unsigned char fastload_drive_code[];
extern const unsigned int fastload_drive_code_size;

/* Entry points within the drive blob (see src/fastload_drive.s jump table). */
#define FASTLOAD_DRIVE_SENTINEL 0x0500   /* Phase 7b: $42 -> $07FF, RTS    */
#define FASTLOAD_DRIVE_ONE_BYTE 0x0503   /* Phase 7c2: send $42 via 2-bit  */

/* Upload the drive-side image to the 1541 and M-E `entry`. After this
 * returns, the drive is running the code at that entry.
 *
 * Chunks the upload into 34-byte M-W frames. Sets ST_NODEV on no-device.   */
void fastload_install_at(unsigned int entry);

/* Convenience wrapper: install + M-E the Phase 7b sentinel entry.          */
void fastload_install(void);

/* Receive one byte via the 2-bit timed protocol. Cycle-tight; lives in
 * src/fastload_recv.s. Returns the byte the drive sent (with our drive's
 * pre-inversion compensating the bus inversion, the host's EOR chain
 * yields the original byte exactly).                                       */
unsigned char __fastcall__ epyx_recv_byte(void);

/* Diagnostic: same handshake + timed reads as epyx_recv_byte, but stores
 * the 4 raw $DD00 reads into $0370..$0373 instead of doing the EOR
 * unscramble. Lets the test see exactly what the host samples.            */
void __fastcall__ epyx_recv_raw(void);

/* Self-test entry point for test_fastload.py. Round-trips a known pattern
 * through drive RAM via M-W + M-R and leaves a footprint at $0340 onwards.
 * See fastload.c for the protocol; the test invokes this via run_at after
 * stamping $0340 with $00.                                                 */
void fastload_selftest(void);

/* Second selftest: M-W + M-E the drive code, then M-R the sentinel it
 * writes ($07FF -> $42). Footprint:
 *   $0350 = $AA when it ran to completion
 *   $0351 = the byte read back from $07FF in drive RAM ($42 on success)
 *   $0352 = ST after the round-trip                                      */
void fastload_selftest_me(void);

/* Third selftest: install, M-E the one-byte 2-bit sender, receive the byte
 * via epyx_recv_byte. Footprint:
 *   $0360 = $AA when it ran to completion
 *   $0361 = the byte received via the 2-bit protocol ($42 on success)
 *   $0362 = ST after install                                            */
void fastload_selftest_2bit(void);

/* Raw-read diagnostic: like _2bit but stores R1..R4 to $0370..$0373.    */
void fastload_selftest_2bit_raw(void);

#endif /* FASTLOAD_H */
