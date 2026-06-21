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

/* --- Epyx FastLoad drive handshake (step 1; see docs/FASTLOAD-FINGERPRINT.md)
 *
 * Meatloaf (and SD2IEC) recognise the Epyx FastLoad cartridge by three M-W
 * uploads to the 1541 stack page followed by an M-E, then run their own native
 * Epyx implementation -- they never execute the uploaded bytes, they only
 * checksum them. So fastload_epyx_upload below is clean-room fingerprint bait
 * sized/summed to match Meatloaf's V2/V3 signature, not real Epyx drive code.
 *
 * The V2/V3 profile (the one both Meatloaf and SD2IEC accept):
 *   M-W $0180, 25 bytes, 8-bit additive checksum $53
 *   M-W $0199, 25 bytes, checksum $A6
 *   M-W $01B2, 25 bytes, checksum $8F
 *   M-E $01A9                                                              */
#define FL_EPYX_MW1      0x0180
#define FL_EPYX_MW2      0x0199
#define FL_EPYX_MW3      0x01B2
#define FL_EPYX_ME       0x01A9
#define FL_EPYX_CHUNK    0x19            /* 25 bytes per chunk               */

/* The 75-byte (3 x 25) fingerprint upload, in the KERNAL ROM. Exported so a
 * static test can read it back and verify the per-chunk checksums.          */
extern const unsigned char fastload_epyx_upload[3 * FL_EPYX_CHUNK];

/* Send the V2/V3 handshake: the three M-W chunks then M-E $01A9. On a Meatloaf
 * (or SD2IEC) drive this hands control to the drive's built-in Epyx handler,
 * which then expects the 256-byte op routine over the wire (step 2). Sets
 * ST_NODEV if the drive doesn't answer.                                      */
void fastload_epyx_install(void);

/* Select the device the fastload helpers target (the shell passes its
   default_device before each fast operation). 8-15; default 8.          */
void fastload_set_device(unsigned char d);

/* 1 if the current device takes the Epyx fast path. First call probes with
   a harmless M-R of the drive reset vector and caches per device: real-DOS
   drives answer their ROM vector and are excluded (the fingerprint install
   would crash them); Meatloaf's emulated memory reads back $00,$00.       */
unsigned char fastload_epyx_capable(void);

/* Demote the current device to "no fast path" (e.g. after the post-install
   header handshake timed out) so listings don't keep retrying.            */
void fastload_epyx_mark_unsupported(void);

/* --- Step 2: host -> drive transmit over the Epyx wire (src/fastload_send.s)
 *
 * After install the drive runs receiveEpyxHeader and clocks bytes IN from us
 * (handshaked, LSB-first, inverted, 1 bit per CLK edge -- not cycle-timed).  */

/* Handshake: wait for the drive's "ready for header", answer, and take the
 * bus (IRQs masked until epyx_send_end). Returns 0 on success, 1 on timeout
 * (drive not in Epyx mode -- IRQs restored, lines released).                 */
unsigned char __fastcall__ epyx_send_begin(void);

/* Clock one byte out to the drive (LSB first, inverted, handshaked).         */
void __fastcall__ epyx_send_byte(unsigned char b);

/* Send the 256-byte "op routine" the drive expects before the header: 255 zero
 * filler bytes then the checksum byte. A tight ASM loop (no cc65 per-byte loop)
 * since it's all pre-transfer overhead.                                       */
void __fastcall__ epyx_send_op(unsigned char checksum);

/* Release the bus and re-enable IRQs.                                        */
void __fastcall__ epyx_send_end(void);

/* Send the "load file" op header the drive expects after install: a 256-byte
 * routine whose only checked property is its 8-bit additive checksum ($86 =
 * "V2 load file"; the bytes are discarded), then the filename length and the
 * filename in REVERSE order. After this the drive opens the file and starts
 * streaming it back over the timed 2-bit protocol (step 3). Returns 0 if the
 * "ready for header" handshake succeeded, 1 if it timed out (the drive never
 * entered Epyx mode -- bad fingerprint, or Epyx not enabled on the drive).   */
unsigned char fastload_epyx_send_header(const char *name, unsigned char namelen);

/* --- Step 3: drive -> host receive over the timed 2-bit protocol
 *               (src/fastload_recv.s) -------------------------------------- */

/* Wait for the drive's per-block "ready" (CLK low then high). 0 = ready,
 * 1 = timeout. Call before each block's length byte.                         */
unsigned char __fastcall__ epyx_wait_ready(void);

/* Receive one byte over the timed 2-bit protocol. The sample timing is
 * hardware-calibrated (see the PAD note in fastload_recv.s).                 */
unsigned char __fastcall__ epyx_recv_byte(void);

/* Receive a whole Epyx-streamed PRG into its embedded load address: the block
 * framing, store, byte count and progress dots all run in tight ASM (the drive
 * blocks on our DATA-high per byte, so cc65 inner-loop overhead slowed every
 * byte). Stores the load address at $02AF/$02B0. Returns the end address
 * (VARTAB), or 0 if fewer than 3 bytes arrived.                              */
unsigned int __fastcall__ epyx_recv_prg(void);

#endif /* FASTLOAD_H */
