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

`make run` delegates to `./run.sh`, which builds the ROM (unless `SKIP_BUILD=1`) and launches `x64sc -kernal build/kernal.bin -basic build/basic.bin`. Run `./run.sh` directly to forward extra VICE arguments, e.g. `./run.sh -warp`. To try the disk commands, attach an image with `DISK=`: `make run DISK=test/data/test.d64` (or `DISK=... ./run.sh`). It mounts a fresh writable *copy* (`build/run-disk.d64`) with `-drive8truedrive`, so a session's `cp`/`rm` never mutate the tracked image. True drive emulation is required — we replaced the KERNAL, so VICE's virtual-device traps never fire. Without a disk, typing `ls` reports a read error after a short timeout rather than wedging.

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

Command history: `readline` keeps the last `HIST_N` (8) submitted non-empty lines in a ring buffer; cursor-up ($91) recalls older entries and cursor-down ($11) walks back toward the fresh line. A recalled line replaces the current one via `replace_line` (step to line start, draw the new text, pad over any leftover of a longer old line). `test_history.py` submits two commands, navigates ≤2 back, edits, and asserts the dispatched command.

Tab completion: TAB ($09) completes a bare command word (no space yet, cursor at the end) against the dispatch table — a unique prefix gets the rest of the name plus a space; ambiguous/unknown prefixes are left alone (`complete_command` in `shell.c`). The CTRL key is mapped to emit $09 in `keytab` so it has a physical trigger (GUI-only). `test_complete.py` injects $09 and checks unique/unknown/ambiguous prefixes.

Utility commands: `peek $addr` / `poke $addr $val` (`src/commands/mem.c`, hex args with optional `$`) read/write live memory; `device <n> [name]` (`fs.c`) sets the default IEC unit that the disk commands use (a `default_device`, boots as 8); an optional name is remembered per device number (`device_name[8..15]`) and reused when `device <n>` is given later without one; `reset` (`builtins.c`) reboots via `soft_reset` in `c_io.s` (`jmp ($FFFC)`). `test_util.py` covers all four (poke→readback, peek→screen, device confirmation, reset→banner+responsive).

File commands: `rm <name>` (`fs.c`) scratches a file by writing "S0:<name>" to the drive command channel via `iec_command` (`iec.s`, which shares the LISTEN/name/UNLISTEN path with `iec_open`, just a different secondary: $6F vs $F0|sa). `cp <src> <dst>` reads src into user RAM at $0800 and writes it to a new PRG `<dst>,p,w` using the IEC write path: `iec_chkout` (LISTEN + data secondary $60|sa), `iec_putbyte`/`iec_puteoi` (CIOUT data bytes; the last with EOI), `iec_unlisten`. `cat <name>` dumps a file's bytes to the screen; `less <name>` pages it (22 lines, "-- more --", any key continues / `q` quits, each page cleared). Both open a read data channel (SA=2) and stream bytes via `iec_getbyte`. Disk-mutating tests (`test_rm.py`, `test_cp.py`) work on a throwaway copy of the fixture (`_scratch*.d64`, gitignored) made fresh at module import; `cat`/`less` are read-only, so `test_pager.py` reads the tracked fixture's SEQ file `doc` (30 lines, l00..l29) directly. The harness detaches the disk before quitting so VICE flushes writes back to the image (a bare quit can leave a just-written file unclosed -- a "splat"); `make run`/`run.sh` `DISK=` mounts a fresh writable copy so a session never mutates the tracked image.

Config: `border <0-15>` / `bg <0-15>` poke the VIC color registers ($D020/$D021); `text <0-15>` sets the KERNAL text color ($0286) for new output; `prompt <str>` changes the prompt symbol main() shows (a `prompt_str` in `shell.c`, set via `set_prompt`; default ">", always followed by a space) — all in `src/commands/config.c`. `test_config.py` checks the registers and that the prompt changed.

**Deferred — AUTOEXEC:** running commands from an AUTOEXEC file at boot is *not* done. The blocker: doing IEC at boot hangs when the drive isn't cooperating. `iec_sendbyte`'s `@wlisten` now times out (see Phase 6 below), so an *absent* device no longer wedges the send — but VICE's empty drive (no disk) *holds DATA low* when sent an OPEN, so `@wlisten` (which waits for DATA low) passes immediately and the boot can still wedge at the still-unbounded `@wready`/`@ack` waits (and a real 1541 isn't ready for ~1-2s after power-on). Fully unblocking AUTOEXEC needs a drive-ready wait (and/or timeouts on `@wready`/`@ack`) before the OPEN. The status-channel gate idea (read channel 15, proceed only on "00") is sound but can't run until the send can't hang.

Cursor and colors: text is white ($01, set in `reset.s`) on the blue screen. The cursor is a **static** (non-blinking) block: CHROUT clears the reverse-video bit (bit 7) of the cell it's leaving and sets it on the cell it lands on, so the cursor cell is always shown reversed — white block, with any character under it in the blue background colour. No timer/IRQ is involved. `screen_text()` masks bit 7, so the block is invisible to text assertions; `test_cursor.py` reads screen codes / colour RAM directly to check it's a static block and white.

SHIFT support: `scan_keyboard` in `src/irq.s` detects either shift key (`SHFLAG`) and, on the found key, folds 'a'-'z' to uppercase and turns cursor-right/down ($1D/$11) into cursor-left/up ($9D/$91) — so capitals and the left arrow are now typeable. Key repeat: a held key re-emits after `KEY_DELAY` (~0.5s) and then every `KEY_RATE` (~15/s), via an `RPTCNT` countdown in the scan (the new-key path arms the initial delay; the held path counts down and re-emits at the rate). `reset.s` now also clears the keyboard buffer count (`NDX`) and `LSTX` at boot. The matrix decode (SHIFT and repeat alike) is GUI-verified (`make run`), since the harness injects into the buffer rather than the matrix. 45 checks pass.

Phase 6 (disk I/O) — done and tested: `src/iec.s` bit-bangs the IEC serial bus on CIA #2 ($DD00) — LISTEN/TALK/secondary/UNLISTEN/UNTALK, `iec_sendbyte` (with EOI), `iec_getbyte`/ACPTR (sets EOI in ST=$90). IRQs are masked per byte. The C side uses a one-arg-at-a-time interface (`src/iec.h`). `src/commands/fs.c` reads the `"$"` directory through shared helpers (`dir_begin`/`dir_line`/`dir_end`, streaming the BASIC-shaped listing one line at a time) used by three commands: `dir` (the full 1541-style listing — block count, quoted name, type, blocks free), `ls` (just the file names, each colored by type via `TEXT_COLOR`/$0286: PRG green, SEQ cyan, USR yellow, REL red, DEL grey — the type word's first letter keys the color; header/blocks-free lines are skipped), and `pwd` (the current device number and remembered name, then the disk name from the header's quoted title, e.g. `9 fd: TEST DISK`). `load <name>` reads a PRG to its load address and reports `loaded $XXXX-$YYYY`; `run` calls the loaded program like SYS via the `run_program` trampoline in `c_io.s` (`jsr` into it, so a program ending in `RTS` returns to the shell prompt; one that loops or takes over never returns). Filenames are folded to uppercase (CBM filenames are uppercase PETSCII). No-device gets a "device not present" ($80) timeout; a present-but-silent drive gets a ~1.4s read-timeout ($02) on every CLK wait so a disk-less `ls` prints "read error" instead of wedging. The *send* path is bounded too: `iec_sendbyte`'s first handshake (`@wlisten`, "is a listener there?") waits for DATA via `wait_data_lo` (~0.7s) and sets $80 on timeout — so targeting a device number that isn't on the bus (e.g. `device 9` then `pwd` when only 8 is present) reports "device not present" instead of hanging forever, even though the present drive ack's the absent device's command bytes under ATN (the absent device only reveals itself once ATN is released and nobody listens for the name). The remaining send waits (`@wready`/`@eoiack`/`@ack`) stay unbounded so a busy-but-present drive (mid-seek) isn't falsely abandoned. On that send-timeout `send_listen` bails through `@fail`, which broadcasts UNLISTEN+UNTALK (which the present drive acknowledges) so it returns to idle and the next command to the real device works (`test_disk.py::test_absent_device_does_not_hang`). Tested against **true drive emulation** (mandatory — our replaced KERNAL means VICE's virtual-device traps never fire): `test/data/test.d64` (regen via `make_test_disk.sh`; its `prog` prints "hello from prog" and RTSes) mounts via `Vice(disk=...)`/`VICE_DISK`; tests poll until transfers finish; `test_run.py` checks `run` prints and then the shell regains the prompt.

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
