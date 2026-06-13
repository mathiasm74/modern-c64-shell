# Epyx fast-receive reliability on dynamic content

## RESOLUTION (2026-06-13): it was VIC-II badlines

The scattered corruption was **not** the Meatloaf, the block boundaries, or the
inter-byte gap (the candidates explored below). It was **VIC-II badlines**: the
receiver samples each byte on fixed CPU-cycle counts, and a badline (~40 cycles
stolen, on every raster line where `(RASTER & 7) == YSCROLL`, only in the
$30-$F7 display window) landing mid-byte slides the sample window off the
drive's timed pairs and corrupts the rest of that byte. `sei` can't stop
badlines -- they're VIC DMA, not interrupts.

**Fix (v0.24 then v0.25):** v0.24 blanked the display (`DEN`) during the load --
what the real Epyx cart does -- which the user confirmed works. v0.25 replaced
the blank with **badline pacing** so the screen stays visible: the per-byte DATA
handshake lets the host stall before each byte (the drive blocks on our
DATA-high), so `_epyx_recv_byte` waits until the raster offset `(RASTER&7)` is
`{0,4,5,6,7}` -- clear of a window that could touch a badline line (YSCROLL=3) --
then releases DATA and samples. This also unblocked fast `ls`/`dir` (the dynamic
directory was garbling for the same badline reason, not its dynamic nature).

The analysis below is the original exploration; kept for the protocol details.
The block-boundary handshake (candidate that survived) is the next thing to
check **if** fast `ls`/`dir` still garbles on hardware despite badline pacing.

---

Status: **analysis for hardware iteration** (the fast receiver is hardware-only;
VICE has no Epyx-capable drive model). Written 2026-06-13 after the user
observed that a **real Epyx FastLoad cartridge** on their Kung Fu Flash loads
GOTD (a dynamic Meatloaf network link) from the same Meatloaf **without
problem**, while our loader desyncs on dynamic content (GOTD, and the directory
when we tried fast `ls`/`dir`). That rules out the Meatloaf's *send* and points
squarely at **our receiver**.

## What the Meatloaf actually sends (authoritative)

From `lib/bus/iec/IECBusHandler.cpp` in the Meatloaf firmware — the real code on
the user's device:

`transmitEpyxByte(data)`:
1. `data = ~data` (all bits inverted on the wire — matches our `EOR #$FF`).
2. **Blocking** `while(!DATA_high && ATN_high)` — wait for the host to release
   DATA ("ready"). On ESP32 this loop periodically does `interrupts();
   noInterrupts();` to feed the watchdog.
3. `timer_start()` — **timer zero is when the Meatloaf *detects* DATA high**,
   not when the host released it.
4. Write pair 1 (CLK=bit7, DATA=bit5) immediately, then
   `timer_wait_until(17/27/37)` and write pairs 2/3/4. Comments say the receiver
   should read the pairs **"15 / 25 / 35 / 45 cycles after DATA HIGH."**
5. Release DATA, wait for DATA low ("got it").

`transmitEpyxBlock()`:
1. `read(m_buffer, m_bufferSize)` — fetch the block's data (this is where
   dynamic content is fetched/generated; runs with interrupts enabled).
2. `writePinCLK(HIGH)` ("ready"), send length byte + data via `transmitEpyxByte`
   **back-to-back with interrupts disabled**, `writePinCLK(LOW)` ("not ready").
3. Repeat until a zero-length block (EOF).

## Two findings

**1. The directory is sent as many tiny blocks.** The directory channel handler
(`iecChannelHandlerDir`) returns **one ~32-byte line per `read()`**. So a 30-file
listing is ~30 blocks of 32 bytes, each with a `CLK low → generate next line →
CLK high` boundary — versus a file's handful of ~254-byte blocks. ~10× the
block boundaries, and a variable `read()` gap (filesystem walk) at each.

**2. Timer-zero is the Meatloaf's *detection* of DATA-high, not our release.**
The gap between them — call it **L** — is the real variable. Our receiver
samples at fixed offsets **from our own DATA release** (+14/24/34/44 cycles),
which only lands inside every pair's stable window when **L is roughly
0–7 µs** (pairs 2–4 are the tight constraint: read at +24/34/44 vs a window of
[L+17,L+27] etc.). A real 1541's detect loop is a tight `lda $1800 / bpl`, so L
is small and rock-steady. The Meatloaf is an ESP32 whose detect loop feeds the
watchdog with brief interrupt windows — so an interrupt landing right as we
release DATA inflates L for that byte, pushing the sample out of the window.

## Why static works but dynamic doesn't

- **FB (local file):** `read()` is flash-fast, few large blocks, and our
  receive loop is tight (`fastload_recv` inner loop) so we release DATA quickly
  after each byte → the Meatloaf's wait is short → few watchdog interrupts → L
  steady. Reliable.
- **GOTD (network file):** same tight receive loop, but the ESP32 is also
  servicing WiFi, so more interrupts land in the per-byte detect window → L
  jitters → desync. The real cart tolerates this; we don't (narrower window).
- **Fast `ls`/`dir` (the reverted experiment):** we parsed each directory line
  *mid-stream*, so our inter-byte gap was large (dir_line bookkeeping) → the
  Meatloaf waited longer per byte → more watchdog interrupts → L jitters →
  garble. Plus ~10× the block boundaries.

## Candidate fixes (ranked, all need a hardware bench)

1. **Buffer the directory, then parse (most promising for fast `ls`/`dir`).**
   Receive the whole `"$"` stream into a RAM buffer with the *tight* receive
   loop (the one FB uses), then parse the buffer for `dir`/`ls`. This removes
   the mid-stream parsing gap entirely, so the directory's within-block timing
   matches a local file's. The between-line generation gaps fall on block
   boundaries, where the CLK handshake already covers them. This is the
   cleanest re-attempt at fast directories.

2. **Re-center the sampling for a larger/typical L.** We empirically tuned
   +14/24/34/44 against *static* FB; the Meatloaf documents +15/25/35/45. If the
   ESP32's median L is a couple of µs higher than a 1541's, nudging the sample
   points later (and re-checking FB still loads) may widen the dynamic margin.
   Sweep +1/+2/+3 on each offset and measure GOTD success rate.

3. **Shrink our per-byte gap to its theoretical minimum.** Anything we can cut
   between `epyx_recv_byte` calls (in `fastload.c` / the receive loops) shortens
   the Meatloaf's wait and reduces the chance of a watchdog interrupt landing in
   the detect window. Already tight for files; matters most if we revisit #1.

4. **Per-byte resync (hard, maybe impossible here).** A real per-byte sync would
   key the sample window off the drive's *actual* first-pair write rather than
   our release. But the Meatloaf sends no separate sync edge — CLK and DATA both
   carry data bits, and the pre-byte bus state is data-dependent — so there's no
   reliable edge to lock onto. This is likely *why* the cart and the Meatloaf
   both rely on a steady L instead.

## Not the cause

- The Meatloaf firmware (the real cart proves the send is fine).
- Our parsing of the directory *format* (standard `$01 $01 | blk | text | $00`;
  the slow standard-IEC path reads it correctly).
- Throughput (the ESP32 is far faster than the C64; it's timing *jitter*, not
  speed).

## Decision for now

Fast `load` of static files stays (reliable). `ls`/`dir`/`pwd` stay on standard
IEC (correct, slow). Candidate #1 (buffered fast directory) is the next thing to
try on the bench; if it survives a Meatloaf, fast directories come back.
