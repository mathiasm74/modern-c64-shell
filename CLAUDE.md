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

`make run` delegates to `./run.sh`, which builds the ROM (unless `SKIP_BUILD=1`) and launches `x64sc -kernal build/kernal.bin -basic build/basic.bin`. Run `./run.sh` directly to forward extra VICE arguments, e.g. `./run.sh -warp`.

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

- `$A0-$A2` jiffy clock (TIME), advanced by the IRQ handler
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

Screen memory at $0400-$07E7 contains C64 *screen codes* (display codes), which are not the same as PETSCII (e.g. 'A' is PETSCII $41 but screen code $01). Use `screen_text()` / `screencode_to_ascii` in `test/lib/vice.py` for assertions. Note: `screenshot()` only works with a real video device, not in headless `-console` mode.

When adding a new feature, add a test that exercises it. The test suite is the safety net that lets us refactor confidently.

## Working with this codebase

- The reset vector at $FFFC/$FFFD must point to the init code in `reset.s`. Don't move this without updating the linker config.
- The IRQ vector at $FFFE/$FFFF must point to the IRQ handler in `irq.s`.
- When implementing a new command, add it to the dispatch table in `src/shell.c` and create a handler in the appropriate `src/commands/*.c` file.
- When adding a KERNAL entry point, update both `src/kernal_stubs.s` and the table in this document.
- Run `make test` before committing. If tests fail, fix them or mark them as expected failures with a comment explaining why.
- Prefer adding new tests over modifying existing ones. Existing tests document expected behavior; changing them silently can hide regressions.

## Current phase

Phase 4 complete: the shell is C. `src/shell.c`'s `main()` prints a `> ` prompt, reads a line (its `readline` echoes printable PETSCII, handles RETURN / DELETE, and passes other control codes straight to CHROUT), reports `COMMAND NOT FOUND: <line>`, and loops — no command table yet (Phase 5). The C reaches the KERNAL through the C-callable `_chrout`/`_getin` shims in `src/c_io.s`, not cc65's conio (which assumes the stock KERNAL we replaced).

Build/link split by authorship: hand-written assembly (reset, IRQ, screen, stubs, the c_io shims) moved to a `KCODE` segment in the KERNAL ROM ($E000); everything cc65 emits keeps its default segments (CODE/RODATA/DATA/BSS/ZEROPAGE) and lands in the BASIC ROM ($A000) / RAM / zero page. `cfg/rom.cfg` defines a `ZP` area for cc65's pseudo-registers and a `RAM` area ($C000-$CFFF) for BSS/DATA and the downward-growing C stack. `reset.s` now initializes the cc65 stack pointer, runs `zerobss`/`copydata`, and `jsr _main` in place of the old echo loop; the Makefile compiles C with cc65 and links `none.lib` for the runtime helpers. Both binaries are still exactly 8KB.

20 checks pass in ~15s. New `test_shell.py` exercises the prompt, unknown-command response, empty-line reprompt, backspace editing, and scrolling under the shell; the echo-loop-specific tests (RETURN starts a new line, raw scroll) moved out of `test_echo.py` since the shell now mediates RETURN.

Caveat (unchanged): tests drive the GETIN -> CHROUT pipeline by writing the keyboard buffer directly. The keyboard *matrix* decode (physical keypress -> PETSCII) can only be verified by typing in the GUI (`make run`).

Next: Phase 5 (command parser and built-ins: a dispatch table in `shell.c`, `cmd_*` handlers in `src/commands/`).

See `PLAN.md` for the full phased plan.

## References

- *Commodore 64 Programmer's Reference Guide* — the canonical hardware and KERNAL reference.
- *Mapping the Commodore 64* by Sheldon Leemon — detailed memory map.
- cc65 documentation: https://cc65.github.io/doc/
- VICE manual, especially the "Binary monitor" and "Machine specifics" sections.
- Sven Petersen's open-source Epyx FastLoad rebuild on GitHub — reference for Phase 7.
- The C64 Wiki (c64-wiki.com) for KERNAL routine details.
