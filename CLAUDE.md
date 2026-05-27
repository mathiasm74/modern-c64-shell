# C64 Shell ROM

A ROM-resident command shell for the Commodore 64, designed to replace the stock BASIC + KERNAL combination with a modern command-line interface. Distributed as a 16KB ROM image suitable for flashing to a OneROM, EasyFlash, or burned EPROM.

## Goals

- Boot directly into a modern shell instead of BASIC's READY prompt.
- Provide a command-line interface with line editing, history, and tab completion.
- Built-in fast loader (Epyx-compatible) for use with stock 1541, SD2IEC, Pi1541, Meatloaf, and 1541 Ultimate.
- File browser and directory navigation for IEC devices.
- Machine language monitor.
- Preserve standard KERNAL entry points so existing machine-language software still works.
- No BASIC interpreter. BASIC programs cannot be run. This is a deliberate tradeoff to reclaim 8KB of ROM space.

## Non-goals

- Running BASIC programs. Use a different ROM slot for that.
- Tape support. The 1530 datasette is not supported; this space is reclaimed.
- GUI or graphics modes. Text only.

## Target hardware

- Commodore 64 (PAL and NTSC).
- Tested in VICE (x64sc) with true drive emulation.
- Final hardware target: OneROM with this image as one of its selectable banks.

## Toolchain

- **cc65 suite** (ca65, cc65, ld65) for assembly and C compilation. Version 2.19 or later.
- **VICE** (x64sc specifically) for emulation and testing. Version 3.7 or later.
- **Python 3** for the test harness.
- **GNU Make** as the build driver.

All tools must be on PATH. Verify with `make check-tools`.

## Build

```
make            # builds build/kernal.bin and build/basic.bin
make test       # builds and runs the test suite
make run        # builds and launches VICE with the ROM
make clean      # removes build artifacts
```

The build produces two 8KB binaries that together form the 16KB ROM:
- `build/kernal.bin` maps to $E000-$FFFF.
- `build/basic.bin` maps to $A000-$BFFF (despite the name, this is not BASIC; it's the shell code).

For OneROM flashing, the two are concatenated: `cat build/basic.bin build/kernal.bin > build/rom16k.bin`.

`make run` delegates to `./run.sh`, which builds the ROM (unless `SKIP_BUILD=1`) and launches `x64sc -kernal build/kernal.bin -basic build/basic.bin`. Run `./run.sh` directly to forward extra VICE arguments, e.g. `./run.sh -warp`. To try the disk commands, attach an image with `DISK=`: `make run DISK=test/data/test.d64` (or `DISK=... ./run.sh`), which adds `-drive8truedrive -8 <image>`. True drive emulation is required — we replaced the KERNAL, so VICE's virtual-device traps never fire. Without a disk, typing `ls` reports a read error after a short timeout rather than wedging.

## Project layout

```
src/
  reset.s          - Reset vector, hardware init, jump to shell main
  irq.s            - IRQ handler (keyboard scan, jiffy clock, CIA ack)
  kernal_stubs.s   - Standard KERNAL entry points at fixed addresses
  shell.c          - Main shell loop, prompt, dispatch
  parser.c         - Command tokenization and parsing
  commands/        - Individual command implementations
    builtins.c     - help, clear, echo, ver
    fs.c           - ls, cd, load, run, cp, rm, mount
    mem.c          - peek, poke, mon
  fastload.s       - Epyx-compatible fast loader
  screen.s         - CHROUT, scroll, cursor management
  c_io.s           - C-callable shims over CHROUT/GETIN
  iec.s            - IEC serial bus (controller side: LISTEN/TALK/ACPTR/...)

cfg/
  rom.cfg          - ld65 linker config

test/
  lib/vice.py      - VICE remote-monitor harness library (Vice class)
  run_tests.py     - Discovers and runs test_*.py, prints a pass/fail summary
  test_*.py        - Per-feature tests (functions named test_*(v))

build/             - Build output (gitignored)
```

## Memory map (planned)

| Range         | Contents                          |
|---------------|-----------------------------------|
| $0000-$0001   | Processor port (standard)         |
| $0002-$00FF   | Zero page (shell working storage) |
| $0100-$01FF   | Hardware stack                    |
| $0200-$03FF   | KERNAL/shell working memory       |
| $0400-$07FF   | Screen RAM                        |
| $0800-$9FFF   | User RAM (loaded programs)        |
| $A000-$BFFF   | Shell code ROM (cc65 output)      |
| $C000-$CFFF   | User RAM                          |
| $D000-$DFFF   | I/O (VIC-II, SID, CIA, color RAM) |
| $E000-$FFFF   | KERNAL ROM (init, IRQ, stubs)     |

## Conventions

### Code organization

- **Hardware setup, IRQ handler, and KERNAL entry points are in assembly** in `src/*.s`. These are timing-sensitive or need fixed addresses.
- **Shell logic, parser, and command implementations are in C** in `src/*.c` and `src/commands/`.
- **Fast loader is in assembly** in `src/fastload.s`. Timing matters too much for C.
- C code calls assembly via standard cc65 calling conventions. Assembly that needs to be called from C is declared with `.export _name` and accessed in C as `name()`.

### KERNAL entry points

Standard KERNAL routines must exist at their published addresses for compatibility:

| Address | Routine  | Purpose                          |
|---------|----------|----------------------------------|
| $FFD2   | CHROUT   | Print character in A             |
| $FFE4   | GETIN    | Read character (non-blocking)    |
| $FFCF   | CHRIN    | Read character (blocking)        |
| $FFBA   | SETLFS   | Set logical file params          |
| $FFBD   | SETNAM   | Set filename                     |
| $FFC0   | OPEN     | Open file                        |
| $FFC3   | CLOSE    | Close file                       |
| $FFC6   | CHKIN    | Set input channel                |
| $FFC9   | CHKOUT   | Set output channel               |
| $FFCC   | CLRCHN   | Restore default channels         |
| $FFD5   | LOAD     | Load file                        |
| $FFD8   | SAVE     | Save file                        |

These are JMPs to implementations elsewhere in the ROM, placed at their fixed addresses by per-entry segments in `cfg/rom.cfg`. Defined in `src/kernal_stubs.s`. Implemented so far (Phase 3): **CHROUT** ($FFD2 -> `chrout_impl` in `src/screen.s`) and **GETIN** ($FFE4 -> `getin_impl`). The rest arrive in later phases (file I/O in Phase 6).

### Zero page

The C64 normally reserves $00-$8F for BASIC and $90-$FF for KERNAL. Since we have no BASIC, $00-$8F is available to the shell. cc65 uses $02-$1F by default for its pseudo-registers; configure this in `cfg/rom.cfg`.

Reserve $90-$FF for KERNAL working storage and keep it compatible with documented usage so loaded programs that poke around in zero page don't break. Locations in use, all at their standard KERNAL addresses:

- `$90` I/O status (ST), set by the IEC routines (EOI $40, device-not-present $80)
- `$A0-$A2` jiffy clock (TIME), advanced by the IRQ handler
- `$94/$95` IEC byte buffer (BSOUR), `$A3-$A5` IEC bit count / filename index / EOI scratch
- `$B7` filename length (FNLEN), `$B9` secondary address (SA), `$BA` device (FA), `$BB/$BC` filename pointer (FNADR)
- `$C5` last key matrix code (LSTX), `$C6` keyboard buffer count (NDX)
- `$D1/$D2` current screen line pointer (PNT), `$D3` cursor column (PNTR), `$D6` cursor row (TBLX)
- `$F3/$F4` current color line pointer (USER), `$F5/$F6` CHROUT register save
- `$F7-$F9` keyboard-scan scratch, `$FB-$FE` reset's string-drawing pointers
- `$0277-$0280` keyboard buffer, `$0286` current text color

The keyboard-scan scratch ($F7-$F9) is deliberately disjoint from the CHROUT/cursor locations so an IRQ-driven scan can't corrupt a CHROUT in progress.

### Naming

- Assembly labels: lowercase with underscores, e.g. `init_vic`, `scan_keyboard`.
- C functions: lowercase with underscores, e.g. `parse_command`, `cmd_ls`.
- Constants in assembly: uppercase, e.g. `SCREEN_RAM = $0400`.
- Command handlers in C: `cmd_<name>`, e.g. `cmd_help`, `cmd_load`.

### Commits

Commit after every passing test. Each commit should leave `make test` green. Use short imperative subject lines: "add CHROUT entry point", "implement ls command", not "Added the CHROUT entry point".

## Testing

The test harness lives in `test/lib/vice.py`. The `Vice` class is a context manager that launches `x64sc` (headless via `-console`), connects to the text remote monitor on a free TCP port, and exposes the machine:

- `read_memory(addr, count)` / `read_byte` / `write_memory(addr, data)` / `write_byte`
- `screen_text()` / `screen_rows()` / `screen_cells()` (screen codes decoded to ASCII)
- `registers()` / `pc()`
- `inject_keys(text)` (writes the keyboard buffer at $0277 and the count at $C6)
- assertions: `assert_screen_contains`, `assert_memory_equals`, `assert_pc_at`, `assert_display_enabled`

A test is a function `test_<name>(v)` in a `test_*.py` module that asserts on the
passed-in `Vice`. `test/run_tests.py` discovers the modules, runs every test
function (one fresh VICE per module, for isolation), and prints a pass/fail
summary. `make test` runs it headless; `make test-verbose` (or `VICE_VERBOSE=1`)
shows the launch command, monitor traffic, and tracebacks. `VICE_HEADLESS=0`
opens the GUI window for debugging.

Screen memory at $0400-$07E7 contains C64 *screen codes* (display codes), which are not the same as ASCII/PETSCII. The shell boots in the lowercase/text charset ($D018 = $16, charset @ $1800) with an ASCII-consistent encoding (`pet2scr` in `src/screen.s`): lowercase 'a' is byte $61 -> screen code $01, uppercase 'A' is $41 -> screen code $41. Use `screen_text()` / `screencode_to_ascii` in `test/lib/vice.py` for assertions; that decoder mirrors the same charset. Note: `screenshot()` only works with a real video device, not in headless `-console` mode.

When adding a new feature, add a test that exercises it. The test suite is the safety net that lets us refactor confidently.

## Working with this codebase

- The reset vector at $FFFC/$FFFD must point to the init code in `reset.s`. Don't move this without updating the linker config.
- The IRQ vector at $FFFE/$FFFF must point to the IRQ handler in `irq.s`.
- When implementing a new command, add it to the dispatch table in `src/shell.c` and create a handler in the appropriate `src/commands/*.c` file.
- When adding a KERNAL entry point, update both `src/kernal_stubs.s` and the table in this document.
- Run `make test` before committing. If tests fail, fix them or mark them as expected failures with a comment explaining why.
- Prefer adding new tests over modifying existing ones. Existing tests document expected behavior; changing them silently can hide regressions.

## Current phase

Phase 8 in progress (polish/daily-use); Phase 7 (fast loader) deferred for now.

Line editing landed: `readline` in `src/shell.c` tracks a cursor index (`pos`) and length (`len`). Cursor left/right ($9D/$1D) move within the line, printable characters insert at the cursor (pushing the tail right), and DELETE removes the character to the cursor's left and closes the gap. Append-at-end and delete-at-end keep a cheap fast path; mid-line edits call `redraw_line`, which steps back to the line start, reprints the whole line plus a trailing space (to wipe a just-deleted cell), and parks the cursor. CHROUT (`src/screen.s`) handles $1D/$9D by moving the cursor, wrapping across rows at column 0/39 (cursor-left at column 0 steps to the previous row's column 39, and vice versa) so a line that wraps to a second screen row edits correctly. `test_lineedit.py` injects cursor codes and asserts the dispatched command (and `$D3`/`$D6` for the cursor column/row, including the wrap).

Cursor and colors: text is white ($01, set in `reset.s`) on the blue screen. The cursor is a **static** (non-blinking) block: CHROUT clears the reverse-video bit (bit 7) of the cell it's leaving and sets it on the cell it lands on, so the cursor cell is always shown reversed — white block, with any character under it in the blue background colour. No timer/IRQ is involved. `screen_text()` masks bit 7, so the block is invisible to text assertions; `test_cursor.py` reads screen codes / colour RAM directly to check it's a static block and white.

SHIFT support: `scan_keyboard` in `src/irq.s` detects either shift key (`SHFLAG`) and, on the found key, folds 'a'-'z' to uppercase and turns cursor-right/down ($1D/$11) into cursor-left/up ($9D/$91) — so capitals and the left arrow are now typeable. Key repeat: a held key re-emits after `KEY_DELAY` (~0.5s) and then every `KEY_RATE` (~15/s), via an `RPTCNT` countdown in the scan (the new-key path arms the initial delay; the held path counts down and re-emits at the rate). `reset.s` now also clears the keyboard buffer count (`NDX`) and `LSTX` at boot. The matrix decode (SHIFT and repeat alike) is GUI-verified (`make run`), since the harness injects into the buffer rather than the matrix. 40 checks pass.

Phase 6 (disk I/O) — done and tested: `src/iec.s` bit-bangs the IEC serial bus on CIA #2 ($DD00) — LISTEN/TALK/secondary/UNLISTEN/UNTALK, `iec_sendbyte` (with EOI), `iec_getbyte`/ACPTR (sets EOI in ST=$90). IRQs are masked per byte. The C side uses a one-arg-at-a-time interface (`src/iec.h`). `src/commands/fs.c` has `ls` (decode the `"$"` directory), `load <name>` (read a PRG to its load address, report `loaded $XXXX-$YYYY`), and `run` (jump via the `run_program` trampoline in `c_io.s`). Filenames are folded to uppercase (CBM filenames are uppercase PETSCII). No-device gets a "device not present" ($80) timeout; a present-but-silent drive gets a ~1.4s read-timeout ($02) on every CLK wait so a disk-less `ls` prints "read error" instead of wedging. Tested against **true drive emulation** (mandatory — our replaced KERNAL means VICE's virtual-device traps never fire): `test/data/test.d64` (regen via `make_test_disk.sh`) mounts via `Vice(disk=...)`/`VICE_DISK`; tests poll until transfers finish; the destructive `run` test is isolated in `test_run.py`.

Phase 6 leftovers (when resumed): the `cd` command, and the formal KERNAL file entry points at their fixed addresses (SETLFS $FFBA … LOAD $FFD5) — disk I/O currently uses the internal `iec_*` API. Known limit: a `load` overlapping the shell's working RAM ($C000-$CFFF) would corrupt the loader mid-load (the test program loads at $2000 to stay clear).

Earlier phases (see git history): Phase 4 moved the shell into C; Phase 5 added the parser, dispatch table, and built-ins (`help`/`clear`/`echo`/`ver`/`exit`); the shell then switched to a lowercase-by-default, ASCII-consistent encoding ($D018 = $16; `keytab` in `irq.s` delivers lowercase ASCII; `pet2scr` in `screen.s` maps lowercase to $01-$1A, uppercase at $41-$5A).

Caveats: tests drive GETIN -> CHROUT by writing the 10-byte keyboard buffer directly, so the keyboard *matrix* decode (including SHIFT) and inputs longer than 10 chars still need the GUI (`make run`) or code review — but the line-editing/cursor logic downstream is fully exercised by injecting the codes directly.

Next Phase 8 chunks (the user is choosing the order): command history (up/down), tab completion, cursor blink, AUTOEXEC, more commands (peek/poke/rm/cp/device/reset/mon), config (colors/prompt).

See `PLAN.md` for the full phased plan.

## References

- *Commodore 64 Programmer's Reference Guide* — the canonical hardware and KERNAL reference.
- *Mapping the Commodore 64* by Sheldon Leemon — detailed memory map.
- cc65 documentation: https://cc65.github.io/doc/
- VICE manual, especially the "Binary monitor" and "Machine specifics" sections.
- Sven Petersen's open-source Epyx FastLoad rebuild on GitHub — reference for Phase 7.
- The C64 Wiki (c64-wiki.com) for KERNAL routine details.
