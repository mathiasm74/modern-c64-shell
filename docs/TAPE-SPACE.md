# Tape space in the stock KERNAL

Where a fast loader can be patched into the stock C64 KERNAL, and the evidence
that it is safe to overwrite. Regenerate with:

    python3 tools/kernal_map.py stock-roms/kernal.901227-03.bin

## Why

After `run`, the machine is on stock ROMs and a program that keeps loading —
levels, multi-load titles — gets stock-speed loads, because `$0330` (ILOAD) is
never hooked. A real Epyx cartridge stays resident and wedges LOAD, which is why
it can be dramatically faster on the same drive.

Patching the loader into **ROM** rather than planting it in RAM is what makes it
survive: a RAM wedge at `$C000` dies to `RESTOR`, to RUN/STOP+RESTORE, and to any
program that uses that memory. ROM survives all three. Tape is an explicit
non-goal for this shell (see CLAUDE.md), so tape code is the space to take, and
`SLOT_POKE` can rewrite the served stock KERNAL before it is switched in —
hardware-validated by the colour patch in v0.2.29.

## The map

| range | bytes | what |
|---|---|---|
| `$F533-$F5A8` | 118 | tape LOAD — ILOAD's device 1–2 branch |
| `$F659-$F68D` | 53 | tape SAVE — ISAVE's device 1–2 branch |
| **`$F8E2-$FB8D`** | **684** | tape IRQ handlers and the bit-level read/write |
| `$FBA6-$FC92` | 237 | tape block handling, motor control |
| | **1092** | largest contiguous **684** |

The 684-byte block alone holds what we need: the Epyx receiver is 299 bytes and
the clock-wait 54, leaving ~330 for the drive upload and the LOAD glue.

## Where to hook

`LOAD`'s device dispatch, read out of the ROM rather than recalled:

```
$F4A5  sta $93 / lda #$00 / sta $90     <- ILOAD default
$F4AB  lda $BA                          <- FA, the device
$F4AD  bne $F4B2  /  jmp $F713          <- device 0: illegal
$F4B2  cmp #$03   /  beq $F4AF          <- device 3: illegal
$F4B6  bcc $F533                        <- device 1-2: TAPE
$F4B8  ldy $B7                          <- device 4+: SERIAL, our hook point
```

`$F4B8` is where a serial fast loader takes over. Note the 3 bytes of a `jmp`
there would clobber `ldy $B7` **and** the first byte of the `bne $F4BF` after it,
so the patched-in code has to re-do both before continuing — or hook by pointing
the ROM's own `$FD30` vector-table entry for ILOAD at the new code, which also
has the advantage of surviving a later `RESTOR` by the program.

## How it was established, and what would invalidate it

Roots are every documented way into the KERNAL: the `$FF81-$FFF5` jump table, the
sixteen RAM-vector defaults `RESTOR` copies from `$FD30`, and the NMI/RESET/IRQ
vectors. Tape roots are the `bcc` targets above **plus three IRQ handlers the
tape code installs into `$0314` from its own table at `$FD9B`** — a static trace
cannot follow a handler installed through a vector, and without those three, 684
bytes of tape code merely look unreachable, which is a very different claim.

Three checks back the result:

1. **Nothing outside reaches in.** No instruction outside the candidate ranges
   references an address inside them — this is what catches a data table living
   in the middle of tape code, which control-flow tracing alone would miss.
2. **Indirect jumps are accounted for.** Every `JMP (ind)` in the KERNAL goes
   through a RAM vector whose ROM default is known; none defaults into the
   ranges.
3. **The blocks look like tape.** `$F8E2-$FB8D` makes 39 accesses to tape
   zero-page and `$FBA6-$FC92` makes 19, plus 2 to `$01` (the cassette port).

Limits worth knowing before trusting this further:

- **Static analysis.** A computed or self-modified jump into the ranges would not
  be seen. The one jump *table* found (`$FD9B`) is handled; there could be
  another, though nothing in the reference check suggests it.
- **This KERNAL revision only** (`901227-03`). Re-run the tool against any other.
- **`$E000-$E4D2` is not free** even though it is unreachable from KERNAL entries:
  it is BASIC's overflow into the KERNAL ROM, called from BASIC. The same goes
  for the table regions the tool reports as reached by neither — `$EB48-$EC43`
  and `$EC78-$ED08` are the keyboard decode tables and the VIC init table,
  `$F0BD-$F12A` the KERNAL messages, `$FD30-$FD4F` the vector table itself.
- The tape messages inside `$F0BD-$F12A` ("PRESS PLAY ON TAPE") are also dead
  weight, but they are interleaved with ones we still want ("SEARCHING",
  "LOADING"), so that region is not a clean block and is left alone.
