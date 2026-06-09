# Epyx FastLoad drive fingerprints (Phase 7)

Source-verified record of how the two drive firmwares we care about detect the
Epyx FastLoad protocol. This **corrects two mistakes** baked into commit
`69d41a9` ("fastload 7c2"):

1. `$5A01` was recorded as a "Meatloaf-recognized fingerprint address." It is
   **not an address** — it is sd2iec's CRC-16 of the uploaded drive code. The
   real M-E fingerprint address is **`$01A9`** (V2/V3 cart) or **`$01A2`** (V1).
2. The pivot note said "our drive-side blob becomes a no-op since Meatloaf
   doesn't run it." Half right: neither Meatloaf nor sd2iec *executes* the
   uploaded bytes — but both *fingerprint* them, so the blob's **bytes are
   load-bearing**. They are not a no-op; they must satisfy a checksum.

## The key insight: emulated drives fingerprint, they do not execute

The real Epyx cart uploads a 6502 routine to the 1541's stack page via `M-W`
and starts it with `M-E`. A **real 1541 runs that code**. Meatloaf and sd2iec
do **not** — they recognize the upload and run their own native handler. This
means:

- For **Meatloaf / sd2iec / any emulated drive**: the uploaded payload can be
  **clean-room filler** — any bytes that satisfy the firmware's checksum of the
  upload. We never need the genuine (copyrighted) Epyx drive code.
- For a **real 1541** (or cycle-exact emulation that runs drive code): the bytes
  are executed, so they must be genuine Epyx drive code or a functional
  clean-room equivalent of a 2-bit sender. Out of scope for now — the user's
  only working drive is Meatloaf.

## Meatloaf — `lib/bus/iec/IECFileDevice.cpp::isFastLoaderRequest`

Meatloaf vendors David Hansel's `IECDevice` library. It parses `M-W`/`M-E` DOS
commands and matches each upload chunk against an `MWSignature {address, len,
checksum}`, where `checksum` is the **8-bit additive sum** of the chunk's data
bytes (`checkMWcmd`, lines ~973-988 — it checks the M-W prefix, dest address,
length, and `sum(bytes) == checksum`; it does **not** compare the actual bytes).

```c
static const struct MWSignature epyxV1sig[2]   = { {0x0180,0x20,0x2E}, {0x01A0,0x20,0xA5} };
static const struct MWSignature epyxV2V3sig[3] = { {0x0180,0x19,0x53}, {0x0199,0x19,0xA6}, {0x01B2,0x19,0x8F} };
...
else if( checkMWcmds(epyxV1sig, 2, 10) || checkMWcmds(epyxV2V3sig, 3, 20) ) return true;
else if( m_uploadCtr==12 && strncmp_P(cmd, PSTR("M-E\xa2\x01"), 5)==0 ) m_uploadCtr = 99;  // V1  -> M-E $01A2
else if( m_uploadCtr==23 && strncmp_P(cmd, PSTR("M-E\xa9\x01"), 5)==0 ) m_uploadCtr = 99;  // V2/V3 -> M-E $01A9
if( m_uploadCtr==99 ) { fastLoadRequest(IEC_FP_EPYX, IEC_FL_PROT_HEADER); ... }
```

So the **V2/V3 handshake** is exactly:

| Step | Command | Dest  | Len  | 8-bit checksum of data |
|------|---------|-------|------|------------------------|
| 1    | `M-W`   | $0180 | $19  | $53 |
| 2    | `M-W`   | $0199 | $19  | $A6 |
| 3    | `M-W`   | $01B2 | $19  | $8F |
| 4    | `M-E`   | $01A9 | —    | — |

(V1: two `M-W` chunks `{$0180,$20,$2E}`,`{$01A0,$20,$A5}` then `M-E $01A2`.)

After the handshake Meatloaf calls `receiveEpyxHeader()` (`IECBusHandler.cpp`,
~line 2576), which receives a **256-byte routine over the Epyx 2-bit wire
protocol** and selects the operation by its 8-bit additive checksum:

- `0x26` / `0x86` / `0xAA` = V1 / V2 / V3 **load file**
- `0x0B` (V1 sector read), `0xBA` (V1 sector write), `0xB8` (V2/V3 sector ops)

It then reads the filename/params from fixed offsets in that block, so the
256-byte block has structure (not pure filler) — implement it against
Meatloaf's parsing, not from the real cart. The 2-bit wire timing/bit-mapping is
in `lib/bus/iec/protocol/epyxfastload.cpp` (`epyxcart_send_def`), itself derived
from sd2iec's `llfl-epyxcart.c`.

## sd2iec — `src/doscmd.c`

Different scheme, same address. Detection requires **both** a CRC match and the
M-E address:

```c
// fl_crc_table:      CRC-16 (init 0xFFFF) of all M-W data bytes since last M-E
{ 0x5a01, FL_EPYXCART, RXTX_NONE },
// fl_handler_table:  execution address
{ 0x01a9, FL_EPYXCART, load_epyxcart, 0 },
// run_loader(): match is  (detected_loader == loader && address == ptr->address)
```

`datacrc` starts `0xFFFF`, accumulates over every `M-W` data byte
(`crc16_update`), and resets after each `M-E`. On `M-W` it is matched against
`fl_crc_table` to set `detected_loader`; the Epyx handler entry is not a
catch-all, so `detected_loader` must be `FL_EPYXCART` (CRC `$5A01`) **and** the
`M-E` address must be `$01A9`. sd2iec only ships the V2/V3 address — so
targeting V2/V3 covers both firmwares with one code path.

## Implementation plan (V2/V3, emulated-drive target)

1. `fastload_drive.s` emits the **three V2/V3 `M-W` chunks** above + `M-E $01A9`.
   Payloads are clean-room: 25 bytes each (`$19`) summing to `$53`/`$A6`/`$8F`.
   Tune the 75 concatenated bytes so the CRC-16 (init `$FFFF`) also lands on
   `$5A01`, and sd2iec is satisfied for free. (CRC is forceable by choosing the
   last couple of bytes; keep each chunk's additive sum correct for Meatloaf.)
2. Host sends the **256-byte op block** over the Epyx 2-bit protocol with
   additive checksum `$86` (V2 load), structured per Meatloaf's
   `receiveEpyxHeader` (count/filename layout).
3. Host receiver (`fastload_recv.s`) is the original cart's `LDA`/`LSR`/`EOR`
   unscramble of the returned data stream.
4. Gate on drive type: this path is for Meatloaf/sd2iec/emulated drives. Real
   1541 fast load (genuine or clean-room drive code) stays deferred.

## Sources

- Meatloaf: `idolpx/meatloaf` `lib/bus/iec/IECFileDevice.cpp`,
  `lib/bus/iec/IECBusHandler.cpp`, `lib/bus/iec/protocol/epyxfastload.cpp`.
- sd2iec: `thierer/sd2iec` `src/doscmd.c` (`run_loader`, `fl_crc_table`,
  `fl_handler_table`).
- Cart byte reference (real-1541 path, if ever needed):
  `svenpetersen1965/Epyx-FastLoad` is a *hardware* rebuild (no drive-code source
  — needs an original EPROM dump).
