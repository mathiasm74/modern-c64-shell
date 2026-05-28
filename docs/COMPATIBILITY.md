# Software compatibility matrix

Phase 9 of the project (see PLAN.md): catalogue what real C64 software needs
from the ROM and figure out where our shell ROM stands. The corpus lives in
`test/corpus/` (gitignored — assemble your own; we don't ship copyrighted
images). Each title here records what we saw when we tried to boot/run it
with our ROM in VICE.

Status legend:
- **✅ runs** — reaches its title screen / main loop and accepts input.
- **⚠️ partial** — gets past boot, then misbehaves later.
- **❌ fails** — crashes or wedges before getting useful work done.

Reproducing the ground-truth (stock-ROM) tests: the `Vice` harness now takes
a `stock_roms=True` argument that omits the `-kernal`/`-basic` flags and
lets VICE use its bundled C64 ROMs. Pair with `cart=...` for .crt files; for
.prg files, launch VICE manually with `-autostart <prg>` (the harness
doesn't have an autostart hook yet -- can add one when the bank-swap work
lands and we want CI-runnable matrix updates).

## Matrix

Two VICE columns: **shell-ROM** is our actual environment (the shell at
`$A000` + our minimal KERNAL at `$E000`); **stock-ROM** is plain VICE with
its bundled stock C64 BASIC/KERNAL, which establishes "does this software
work on a *real* C64 at all?" -- the ground truth that the future OneROM
bank-swap design needs to deliver. If a title is `✅` in stock-ROM and
`❌` in shell-ROM, that is a title the bank-swap design will recover.

| Title | Format | Category | VICE (shell) | VICE (stock) | Real HW | Notes |
|-------|--------|----------|------|------|---------|-------|
| Ghostbusters | .crt (Magic Desk, type 19) | ML cart | ❌ | ✅ | — | Stock ROMs deliver the full game; our shell fails because the cart calls internal `$E3BF`/`$E453`/`$E51B` inside our KCODE. Won by bank-swap. |
| fb64-turbo   | .prg, BASIC stub + ML at $0801 | BASIC + ML loader | ❌ | ✅ | — | Autostart-loads under stock BASIC, the screen shows the FB64-TURBO UI. Calls 7 BASIC-ROM addresses + 18 internal KERNAL — won by bank-swap. |

---

## Ghostbusters (Activision, Magic Desk cart)

**File:** `test/corpus/Ghostbusters.crt` (80 KB, 10 banks × 8 KB, EXROM=0/GAME=1).

**Boot path:** the cart's `CBM80` signature at `$8004` is detected (our
`reset.s` honors it now, see commit). `JMP ($8000)` lands at `$804B`, the
cart's cold-start. Disassembling the first ~70 bytes:

```
$804B  LDX #$08
$804D  STX $D016                 ; VIC ctrl2 = 8-col mode
$8050  JSR $FDA3                 ; IOINIT  (stubbed RTS)
$8053  LDA #$00; LDX #$18
$8057  STA $D400,X; DEX; BPL $8057   ; zero SID
$805D  TAY
$805E  STA $0002,Y               ; zero $0002..$0101
$8061  STA $0200,Y               ; zero $0200..$02FF
$8064  STA $0300,Y               ; zero $0300..$03FF
$8067  INY; BNE $805E
$806A  LDX #$3C; LDY #$03
$806E  STX $B2; STY $B3          ; ZP pointer = $033C
$8072  LDX #$00; LDY #$A0
$8076  JSR $FD8C                 ; SET_MEMTOP (stubbed RTS)
$8079  JSR $FD15                 ; RESTOR     (stubbed RTS)
$807C  LDA #$03; STA $9A         ; DFLTO = 3 (screen)
$8080  LDA #$00; STA $99         ; DFLTN = 0 (keyboard)
$8084  JSR $E51B                 ; CLRSCR     ← INSIDE OUR KCODE
$8087  JSR $FF5E                 ; (stubbed RTS)
$808A  JSR $E453                 ; (BASIC init) ← INSIDE OUR KCODE
$808D  JSR $E3BF                 ; (BASIC init) ← INSIDE OUR KCODE
$8090  JSR $81E9                 ; cart-internal
$80A3  JSR $0100                 ; stack-pointer call (very stock-KERNAL-specific)
$80D3  JSR $FC85                 ; (stubbed RTS)
$80F0  JMP $8811                 ; cart-internal
```

**Diagnosis:** five of those calls (`$FDA3`, `$FD8C`, `$FD15`, `$FF5E`,
`$FC85`) land in free `$FF` fill in our KERNAL ROM — we added RTS stubs at
all of them (`STUB_LEGACY_*` segments in `cfg/rom.cfg`). But three calls —
`$E51B` (CLRSCR), `$E453`, `$E3BF` — land in addresses that are **inside
our own KCODE**, where our reset/IRQ/screen/iec routines live. The cart's
`JSR` to those addresses lands on whatever instruction-stream byte happens
to be there, executing nonsense and ending up wandering through our iec
wait loops. There is also a `JSR $0100` (into the stack page) which
depends on a very specific stock-KERNAL stack state.

**Verdict:** *won't fix cheaply.* Ghostbusters is a "depends on exact stock
KERNAL ROM contents" cart. Supporting it would require either putting
working code at `$E3BF`, `$E453`, `$E51B` — which means refactoring our
KCODE layout to leave those addresses free — or reproducing the stock
KERNAL byte-for-byte. Either path is large and the user is better served
by selecting the stock-KERNAL OneROM slot for this kind of cart.

The diagnosis is itself a Phase 9 win: we have a concrete example of the
"abuses ROM internals" category, and the legacy RTS stubs we added while
chasing it (`$FC85`, `$FD15`, `$FD50`, `$FD8C`, `$FDA3`, `$FF5E`, `$FF81`)
will help any software that calls IOINIT / RAMTAS / RESTOR / CINT
directly via the implementation addresses rather than the official jump
table. The shell ROM did *not* hang — our IEC send-path timeouts kept
the bus from wedging even with the cart's garbage execution.

---

## fb64-turbo (BASIC + ML loader)

**File:** `test/corpus/fb64-turbo.prg` (3661 bytes, loads at `$0801`, ends
`$164B`). Standard BASIC stub: line 31 `SYS 2061` (= `SYS $080D`).

**Boot path:** writing the file to `$0801` and jumping to `$080D` directly,
the cold-start does:
- `TSX` followed by a copy loop from `$156E,X` to `$00FC,X` — depends on the
  BASIC `SYS` having left the stack pointer at a specific value. Without
  BASIC, the source range it copies from runs past the end of loaded data
  ($164B) into uninitialized memory.
- `JMP $1520` — which writes to screen RAM (`$07E6,Y`) and then operates on
  the BASIC zero-page / pointer area (`$0367-$039B`), which BASIC would have
  initialized but we never do.

**Static survey of jumps:**
- **7 distinct addresses in `$A000-$BFFF`** (`$A103, $A27A, $A51C, $A7AE,
  $A82A, $A9BD, $B9A4`). On a stock C64 these are BASIC ROM routines; in
  our memory map that range is *our shell ROM*. Any `JSR` there lands in
  cc65-compiled C code, executing garbage.
- **18 distinct internal KERNAL addresses** outside our pinned jump table
  (`$E19F, $E555, $E619, $E725, ...`).

**Observed run:** after `run_at($080D, 3.0s)`, PC lands back at `$FFE4`
(our GETIN), a single `!` appears at row 0 col 0, and execution otherwise
returns to the shell's readline loop -- the program installed nothing
useful, the misdirected calls were absorbed harmlessly because the BASIC
ROM area now has our valid (but unrelated) shell ROM bytes in it. Notably
nothing crashed, which is itself diagnostic: the system stayed coherent
under a flood of misdirected calls.

**Verdict:** *won't fix.* fb64-turbo is fundamentally BASIC-dependent
(7 BASIC ROM calls, BASIC zero-page assumptions, `SYS`-context stack
state). This belongs to the "needs full BASIC interpreter" bucket, which
the project explicitly does not implement -- the user runs this from a
stock-BASIC OneROM slot.
