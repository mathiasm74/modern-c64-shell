# Hardware Memtest ROM

A standalone diagnostic ROM for distinguishing bus-integrity faults on the
C64+OneROM hardware. `make memtest-flash` programs it; on next power-on the
C64 displays a fixed test pattern that's easy to read by eye.

Build / flash:

```
make memtest             # build build/memtest-{kernal,basic}.bin + onerom fw
make memtest-flash       # build + program + reboot the connected OneROM
```

The shell ROM is untouched; this is a fully separate build. `make` (without
arguments) still builds the shell.

## Design notes (v2)

The first version of this used JSR/RTS and PHA/PLA to keep the code
readable, and on real hardware froze partway through (the user's first
test got through the banner + one bank read, then died). The first version
also used a parameterized `puthex` subroutine, so every test cell pushed +
popped from the stack. **Any** bus bit-drop on a stack pop sends `RTS` to
garbage, and the bus is exactly what we're testing.

This version is intentionally stack-free:

- No `JSR`/`RTS`. The whole test is a linear sequence of inline operations.
- No `PHA`/`PLA`. Byte values pass through registers (`A` and `X`); the
  `HEX_BYTE` macro keeps the source byte in `X` while it writes both nibbles.
- Only one tight loop (`SCAN`), and its counters live in zero page, not on
  the stack.
- Static labels are painted once at boot from a packed table; the walker
  uses two self-incrementing zero-page pointers, no register-indexed
  addressing into a >256-byte table.

If the test makes it onto the screen at all, every section before the last
visible row ran to completion -- there's no pending stack frame whose
corrupted pop could redirect execution. The freeze symptom from v1 turns
into a "stops painting after row N" symptom in v2, which itself tells you
something: it means the BASIC reads in that section managed to corrupt
zero-page or screen RAM enough to break the linear code path.

## What the screen shows

```
MEMTEST V2

BANK A0 A8 B0 B8 BF                   <- labels = expected values
     XX XX XX XX XX                   <- actual reads from BASIC bank

D1 EXP 01 02 04 08 10 20 40 80        <- walking-1 expected
D1  RD XX XX XX XX XX XX XX XX        <- walking-1 actual

D0 EXP FE FD FB F7 EF DF BF 7F        <- walking-0 expected
D0  RD XX XX XX XX XX XX XX XX        <- walking-0 actual

KRNL EFFE EXP EF RD XX                <- KERNAL-bank sanity check

SCAN A050 N=03E8 ERR=XXXX LAST=XX     <- transient: 1000 reads of $A050
```

The row-2 BANK labels (`A0 A8 B0 B8 BF`) carry double duty: they're column
headers (the high byte of the address being read -- `A0` = `$A000`, etc.)
AND the expected value at that address. Match row 2 against row 3
cell-by-cell.

## What each test isolates

### BANK -- 5 corners of the BASIC ROM

`A000`, `A800`, `B000`, `B800`, `BFFF`. Each holds its high byte as a
sentinel. Looks at:

- **A11 / A12 address lines.** `$A000` vs `$A800` differs only in A11;
  `$A000` vs `$B000` differs only in A12. If A11 is stuck low, both `$A000`
  and `$A800` will read the same value.
- **BASIC bank `/CS` routing.** If the OneROM is responding when BASIC's CS
  is asserted but with the wrong slot data, all five cells might read a
  constant value (e.g. a single repeating byte like `$4A` or `$AA`), or
  they might read what KERNAL has at the corresponding low addresses.
- **High corner aliasing.** `$BFFF` is the last byte of BASIC; useful to
  spot wraparound from KERNAL bleeding into the BASIC range.

### D1 -- walking-1 data lines

8 bytes at `$A100..$A107` holding `$01, $02, $04, $08, $10, $20, $40, $80`.
Each byte has exactly one data line driven high.

- If D0 is **stuck low**, the first cell reads `$00` instead of `$01`.
- If D7 is **stuck high**, all eight cells read with bit 7 set
  (`$81, $82, $84, ... $80`).
- If D4 is **shorted to D5**, both `$10` and `$20` read as `$30`.

### D0 -- walking-0 data lines

Same idea, opposite polarity: `$FE, $FD, $FB, $F7, $EF, $DF, $BF, $7F`. One
data line driven low per byte. Catches stuck-high faults that walking-1
misses (a bit stuck high looks correct in walking-1 because the expected
value already has it set in 7 of 8 cells).

Together, D1 + D0 covers every bit in both polarities and is sufficient to
identify any single stuck/floating data line.

### KRNL -- KERNAL ROM control

A sentinel byte `$EF` placed at `$EFFE` in the KERNAL bank. If this reads
correctly while the BASIC row shows garbage, the fault is specific to the
BASIC bank (its `/CS` line, its socket, or its OneROM slot routing). If
this *also* reads wrong, the issue is upstream of bank selection (address
or data bus, CPU side).

### SCAN -- transient vs. persistent

Reads the single byte at `$A050` (= `$55`) 1000 times in a tight loop, with
no other bus activity between reads. Counts how many returned something
other than `$55` and records the last bad value.

- `ERR=0000` -- 100% of reads were correct. The fault (if any in the rows
  above) is **persistent**: the bus settles to the same wrong value every
  time.
- `ERR=03E8` (= 1000) -- 100% of reads were wrong. Still persistent, just
  consistently wrong.
- `ERR=XXXX` for some middle value -- **transient** fault. The bus
  sometimes returns the right byte, sometimes not. Typically points to
  marginal signal integrity: a flaky `/CS` jumper, a long unshielded wire
  picking up noise, or a too-slow ROM emulator vs. the C64's address-stable
  window.
- `LAST=XX` -- the most recent wrong byte. If transient, this tells you
  what value the bus *defaults* to when the read fails (often `$FF`,
  `$00`, or a pattern that hints at which bus is misbehaving).

## Interpreting common failure modes

### "BANK row all reads the same value, KRNL row reads correctly"

Persistent BASIC-bank fault. The BASIC `/CS` (or the OneROM serve algorithm
for BASIC) is the suspect. The KRNL row reading `EF` correctly rules out
the address/data bus and the CPU.

If the constant value gives you a binary hint (`$4A` = `0100_1010`,
`$AA` = `1010_1010`) it might LOOK like a stuck-bit pattern, but with the
KRNL row reading fine the data bus is healthy -- the OneROM is just *serving*
that constant (e.g. an unprogrammed slot, or the same byte of a wrong slot
served repeatedly because the BASIC-bank selection isn't routing to the
right slot).

### "BANK and walking rows read correctly, KRNL row fails"

KERNAL-bank fault. Less likely than BASIC failure given the v1 banner
result, but possible if the wiring jumpers have an issue on the KERNAL CS
path instead.

### "Test stops partway through, no SCAN row"

Either the linear test code is hitting a `KIL`-style invalid opcode (real
bus issue: an instruction fetch from KERNAL is being corrupted somehow), or
RAM/ZP writes are unstable enough that the label-paint loop terminates
early on a corrupted byte read. The further the test gets before stopping,
the more of the diagnostic you can trust.

If you don't even see the title banner: KERNAL ROM reads are failing too
(or the reset vector at `$FFFC` is reading wrong). At that point, fall back
to the pure-stock baseline (`make onerom-pure-stock-flash`) -- if even that
doesn't boot, the C64-side wiring is broken, not anything ROM-specific.

## Source layout

- `src/memtest/memtest.s` -- test code + label-painting walker, lives in
  the KERNAL bank
- `src/memtest/memtest_basic.s` -- sentinel bytes pinned in the BASIC bank
- `cfg/memtest.cfg` -- linker config
- `cfg/onerom-memtest.json` -- OneROM firmware (USB plugin + memtest banks)
