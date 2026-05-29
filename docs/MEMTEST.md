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

## What the screen shows

```
MEMTEST V1

BANK  A000 A800 B000 B800 BFFF
EXP    A0   A8   B0   B8   BF
READ   XX   XX   XX   XX   XX

D1   EXP 01 02 04 08 10 20 40 80
D1   RD  XX XX XX XX XX XX XX XX

D0   EXP FE FD FB F7 EF DF BF 7F
D0   RD  XX XX XX XX XX XX XX XX

KRNL EFFE EXP EF READ XX

SCAN A050 N=03E8 ERR=XXXX  LAST=XX
```

The "READ" / "RD" / "READ" cells turn **green** when every byte matches the
"EXP" cells above them, **red** otherwise. The SCAN row turns green if all
1000 reads matched, red if any didn't.

## What each test isolates

### BANK row -- 5 corners of the BASIC ROM

`A000`, `A800`, `B000`, `B800`, `BFFF`. Each holds its high byte as a
sentinel. Looks at:

- **A11 / A12 address lines.** `$A000` vs `$A800` differs only in A11;
  `$A000` vs `$B000` differs only in A12. If A11 is stuck low, both `$A000`
  and `$A800` will read the same value.
- **BASIC bank `/CS` routing.** If the OneROM is responding when BASIC's CS
  is asserted but with the wrong slot data, all five cells might read a
  constant value (e.g. a single repeating byte like `$4A`), or they might
  read what KERNAL has at the corresponding low addresses.
- **High corner aliasing.** `$BFFF` is the last byte of BASIC; useful to
  spot wraparound from KERNAL bleeding into the BASIC range.

### D1 row -- walking-1 data lines

8 bytes at `$A100..$A107` holding `$01, $02, $04, $08, $10, $20, $40, $80`.
Each byte has exactly one data line driven high.

- If D0 is **stuck low**, the first cell reads `$00` instead of `$01`.
- If D7 is **stuck high**, all eight cells read with bit 7 set
  (`$81, $82, $84, ... $80`).
- If D4 is **shorted to D5**, both `$10` and `$20` read as `$30`.

### D0 row -- walking-0 data lines

Same idea, opposite polarity: `$FE, $FD, $FB, $F7, $EF, $DF, $BF, $7F`. One
data line driven low per byte. Catches stuck-high faults that walking-1
misses (a bit stuck high looks correct in walking-1 because the expected
value already has it set in 7 of 8 cells).

Together, D1 + D0 covers every bit's both polarities and is sufficient to
identify any single stuck/floating data line.

### KRNL row -- KERNAL ROM control

A sentinel byte `$EF` placed at `$EFFE` in the KERNAL bank. If this reads
correctly while the BASIC row shows garbage, the fault is specific to the
BASIC bank (its `/CS` line, its socket, or its OneROM slot routing). If
this *also* reads wrong, the issue is upstream of bank selection (address
or data bus, CPU side).

### SCAN row -- transient vs. persistent

Reads the single byte at `$A050` (= `$55`) 1000 times in a tight loop, with
no other bus activity between reads. Counts how many returned something
other than `$55` and records the last bad value.

- `ERR=0000` -- 100% of reads were correct. The fault (if any in the rows
  above) is **persistent**: the bus settles to the same wrong value every
  time.
- `ERR=03E8` (= 1000) -- 100% of reads were wrong. Still persistent, but
  consistently wrong.
- `ERR=XXXX` for some middle value -- **transient** fault. The bus
  sometimes returns the right byte, sometimes not. Typically points to
  marginal signal integrity: a flaky `/CS` jumper, a long unshielded wire
  picking up noise, or a too-slow ROM emulator vs. the C64's address-stable
  window.
- `LAST=XX` -- the most recent wrong byte. If transient, this tells you
  what value the bus *defaults* to when the read fails (often `$FF`,
  `$00`, or a pattern that hints at which bus is misbehaving).

## Interpreting the user's `4A` / "JJJJJJ" case

In the prior session, banner text in BASIC ROM printed as repeated `J`
(screen code `$4A`). After flashing memtest, the expected reading is:

- **BANK row** all `$4A` -> persistent BASIC-bank fault. Combined with the
  KRNL row reading `EF` correctly, this confirms BASIC `/CS` (or the BASIC
  slot serve algorithm) is broken on this hardware while KERNAL is fine.
- **D1 row** all `$4A` and **D0 row** all `$4A` -> same diagnosis;
  walking-1 and walking-0 patterns collapse to the same constant when the
  fault overrides the actual data.
- **SCAN ERR=0000 LAST=00** -> persistent: it's `$4A` every read, not a
  flaky line.

If `$4A` is the persistent value and `$4A = 0100_1010`, the
"is-it-a-stuck-bit" guess would be that D1, D3, D6 are driven high and
D0, D2, D4, D5, D7 are driven low -- but that pattern would also affect
KERNAL reads, which they're not. So it's much more likely the OneROM is
*serving* the constant `$4A` (e.g. an unprogrammed slot, or the same byte
of a wrong slot served repeatedly because the address bits aren't
reaching the serve algorithm).

## Source layout

- `src/memtest/memtest.s` -- test code, lives in the KERNAL bank
- `src/memtest/memtest_basic.s` -- sentinel bytes pinned in the BASIC bank
- `cfg/memtest.cfg` -- linker config
- `cfg/onerom-memtest.json` -- OneROM firmware (USB plugin + memtest banks)
