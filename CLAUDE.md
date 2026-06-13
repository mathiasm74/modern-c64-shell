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
make             # builds build/kernal.bin and build/basic.bin
make test        # builds and runs the test suite
make run         # builds and launches VICE with the ROM
make onerom      # builds a One ROM firmware image from both halves
make onerom-flash # builds + flashes a connected One ROM
make clean       # removes build artifacts
```

The build produces two 8KB binaries that together form the 16KB ROM:
- `build/kernal.bin` maps to $E000-$FFFF.
- `build/basic.bin` maps to $A000-$BFFF (despite the name, this is not BASIC; it's the shell code).

For a raw 16KB blob (EPROM/EasyFlash) the two are concatenated: `cat build/basic.bin build/kernal.bin > build/rom16k.bin`.

### One ROM firmware

`make onerom` builds a flashable [One ROM](https://onerom.org/) firmware image with the `tools/onerom` CLI (a Mach-O universal binary, kept untracked — it's ~10MB). It reads `cfg/onerom.json` and writes `build/onerom-<board>.bin`. The config has **two slots**:

- **Slot 0:** the USB *system plugin* (`https://images.onerom.org/plugins/system/usb/v…/plugin.bin`, fetched/cached on build). Without it the device can't accept USB commands once it's serving ROM, so `onerom reboot` would refuse with *"does not support being rebooted into running mode."*. To bump the plugin version, edit the URL in `cfg/onerom.json` (or regenerate with `tools/onerom firmware build --plugin usb --save-config …`).
- **Slot 1:** both ROM halves as one multi-ROM set — `kernal.bin` and `basic.bin` as two 2364s served by the `two_cs_one_addr` algorithm. Two active-low chip selects (the C64's KERNAL `/CS` at U4 and BASIC `/CS` at U3) over the shared A0–A12 bus. (A single CS line can't distinguish KERNAL vs BASIC vs neither, so it genuinely needs both selects; the One ROM CLI also rejects mixing active-low/active-high in one set.) ROM order in the config is the CS-pin order — `kernal.bin` first, `basic.bin` second.

The board defaults to `fire-24-e`; override for your hardware: `make onerom ONEROM_BOARD=fire-28-a` (`tools/onerom scan --list-boards` lists them). `make onerom-flash` programs a connected device and then reboots it into the running (byte-serving) state in one step; set `ONEROM_SERIAL='5*'` to pick one of several. `onerom scan` after that should show **Running** instead of Stopped.

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

These are JMPs to implementations elsewhere in the ROM, placed at their fixed addresses by per-entry segments in `cfg/rom.cfg` (`STUB_FILE_IO` $FFBA-$FFD1, `STUB_CHROUT` $FFD2, `STUB_LOAD_SAVE` $FFD5, `STUB_GETIN` $FFE4). Defined in `src/kernal_stubs.s`. The file-I/O entries are thin shims over the `iec_*` primitives in `iec.s`: SETLFS/SETNAM record params into the KERNAL-standard zero-page (LA $B8, FA $BA, SA $B9, FNLEN $B7, FNADR $BB/$BC); OPEN/CLOSE/CHKIN/CHKOUT call the matching `iec_*` routine; CLRCHN releases any held IEC channels and restores DFLTN=0/DFLTO=3; CHRIN reads from `iec_getbyte` if DFLTN >= 8, else blocks on the keyboard via GETIN. LOAD forces bus channel 0 (the load channel) regardless of SETLFS's SA — SA only decides whether to honor the file's embedded load address (SA=0, the BASIC LOAD convention) or use the X/Y override (SA!=0). CHRIN preserves X and Y per the standard so callers can use a register as a loop counter (the underlying `_iec_getbyte` clears them as part of cc65's fastcall return). CHROUT ($FFD2) routes by DFLTO: screen normally, the IEC channel after CHKOUT — with the stock KERNAL's one-byte deferral (WRPEND $94 / WRBYTE $02BE) so CLRCHN can send the final byte with EOI and the drive finalizes the file instead of leaving a splat. Single-file model: we don't keep a per-LFN open-file table; the most recent SETLFS values are the implicit "current" file. `test_kernal_io.py` writes ML stubs into RAM and invokes them with the harness's `run_at(addr, seconds)` to exercise each entry end-to-end. **CHROUT** ($FFD2 -> `chrout_impl` in `src/screen.s`) and **GETIN** ($FFE4 -> `getin_impl`) date from Phase 3.

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
summary. `make test` runs it headless; modules run **in parallel** (one VICE each,
up to 8 workers -- `VICE_JOBS=1` restores serial for debugging) and each
module's wall time is printed for spotting slowpokes. Prefer polled waits
(loop `run_for` until the expected text appears) over long fixed sleeps --
VICE runs `-warp`, so completion usually beats the timeout by a lot.
`make test-verbose` (or `VICE_VERBOSE=1`)
shows the launch command, monitor traffic, and tracebacks. `VICE_HEADLESS=0`
opens the GUI window for debugging.

Screen memory at $0400-$07E7 contains C64 *screen codes* (display codes), which are not the same as ASCII/PETSCII. The shell boots in the lowercase/text charset ($D018 = $16, charset @ $1800) with an ASCII-consistent encoding (`pet2scr` in `src/screen.s`): lowercase 'a' is byte $61 -> screen code $01, uppercase 'A' is $41 -> screen code $41. Use `screen_text()` / `screencode_to_ascii` in `test/lib/vice.py` for assertions; that decoder mirrors the same charset. Note: `screenshot()` only works with a real video device, not in headless `-console` mode.

When adding a new feature, add a test that exercises it. The test suite is the safety net that lets us refactor confidently.

## Working with this codebase

- The reset vector at $FFFC/$FFFD must point to the init code in `reset.s`. Don't move this without updating the linker config.
- The IRQ vector at $FFFE/$FFFF must point to the IRQ handler in `irq.s`.
- When implementing a new command, add it to the dispatch table in `src/shell.c` and create a handler in the appropriate `src/commands/*.c` file. The dispatch table is kept sorted alphabetically and lives in the `RODATA2` segment (`#pragma rodata-name`), which `cfg/rom.cfg` loads into the KERNAL ROM rather than the smaller BASIC ROM where the rest of the cc65 output sits. `cmd_help` (which prints the commands in three indented 12-wide columns, column-major over the sorted table) lives in `CODE2` for the same reason. Other things can be relocated to KERNAL via the same pragma pair when the BASIC ROM gets tight.
- When adding a KERNAL entry point, update both `src/kernal_stubs.s` and the table in this document.
- Run `make test` before committing. If tests fail, fix them or mark them as expected failures with a comment explaining why.
- Prefer adding new tests over modifying existing ones. Existing tests document expected behavior; changing them silently can hide regressions.

## Current phase

Phase 9 in progress (software compatibility testing); Phase 7 (fast loader) still deferred. The KERNAL file-I/O entry points and a `CBM80` cartridge autostart check landed at the start of Phase 9 so real software can boot. `test/corpus/` holds the locally-collected PD/homebrew test images (gitignored — copyrighted material does not enter the repo); `docs/COMPATIBILITY.md` records per-title results. A handful of unused-stock-KERNAL implementation addresses ($FC85, $FD15 RESTOR, $FD50 RAMTAS, $FD8C, $FDA3 IOINIT, $FF5E, $FF81 CINT) are stubbed RTS so software that JSR's directly to them (instead of the official $FF81+ table) doesn't crash; we already did the equivalent setup in `reset.s`.

The corpus showed quickly that with the shell ROM as the only environment, real C64 software mostly fails — it expects stock BASIC/KERNAL bytes we don't (and can't economically) reimplement. The architectural answer is to **hand off to stock ROMs at program-launch time**, via the [One ROM Bus Control Protocol](https://github.com/piersfinlayson/rom-bus-control-protocol) (`user/host-control` plugin). The 6502 reference library is now vendored at `src/rbcp/` (assembled into a `RBCP_CODE` segment in KERNAL ROM where we have slack), with `src/rbcp/rbcp_config.s` tailored for our memory map (command page at `$E0`, back-channel at `$E100-$E2FF`, ZP block at `$80-$8F`). `cfg/onerom-stock.json` adds the host-control plugin (slot 1) and a stock-ROM chip_set (slot 3); stock C64 ROMs live in `stock-roms/` (gitignored, user-supplied). `make onerom-stock` builds the 4-slot firmware. The RAM-resident trampoline that drives the bank swap is in `src/rbcp/launch.s`: `_rbcp_launch_stock` (KCODE) copies the whole RBCP_CODE block from ROM to RAM at $C800, patches the trampoline's final `JMP $0000` operand with the entry address, and `JMP`s into the in-RAM trampoline; the trampoline then `SEI`s and drives `rbcp_reset → enter_cmd_resp → load_slot (3 → RAM slot 1) → switch_and_exit → JMP entry`. `cmd_runstock` (fs.c, in CODE2 to fit the BASIC ROM budget) is the C-side glue. `test_rbcp.py` verifies the segment layout and that the launcher does the right copy/patch (the actual swap is unobservable in VICE since the One ROM model isn't emulated). See `docs/RBCP-DESIGN.md` for what still needs hardware validation.

Line editing landed: `readline` in `src/shell.c` tracks a cursor index (`pos`) and length (`len`). Cursor left/right ($9D/$1D) move within the line, printable characters insert at the cursor (pushing the tail right), and DELETE removes the character to the cursor's left and closes the gap. Append-at-end and delete-at-end keep a cheap fast path; mid-line edits call `redraw_line`, which steps back to the line start, reprints the whole line plus a trailing space (to wipe a just-deleted cell), and parks the cursor. CHROUT (`src/screen.s`) handles $1D/$9D by moving the cursor, wrapping across rows at column 0/39 (cursor-left at column 0 steps to the previous row's column 39, and vice versa) so a line that wraps to a second screen row edits correctly. DELETE ($14) wraps the same way: at column 0 it steps back to the previous row's column 39 before blanking, so backspacing across a wrap erases the right cell and moves the cursor (it used to stick at column 0 — dropping the char from the line buffer while leaving the screen unchanged). `test_lineedit.py` injects cursor codes and asserts the dispatched command (and `$D3`/`$D6` for the cursor column/row, including both the cursor-left and the DELETE wrap).

Command history: `readline` keeps the last `HIST_N` (8) submitted non-empty lines in a ring buffer; cursor-up ($91) recalls older entries and cursor-down ($11) walks back toward the fresh line. A recalled line replaces the current one via `replace_line` (step to line start, draw the new text, pad over any leftover of a longer old line). `test_history.py` submits two commands, navigates ≤2 back, edits, and asserts the dispatched command.

Tab completion: TAB ($09) completes a bare command word (no space yet, cursor at the end) against the dispatch table — a unique prefix gets the rest of the name plus a space; ambiguous/unknown prefixes are left alone (`complete_command` in `shell.c`). CTRL+I produces $09 (see CTRL below), so completion has a physical trigger. `test_complete.py` injects $09 and checks unique/unknown/ambiguous prefixes.

Utility commands: `peek $addr` / `poke $addr $val` (`src/commands/mem.c`, hex args with optional `$`) read/write live memory; `device <n> [name]` (`fs.c`) sets the default IEC unit that the disk commands use (a `default_device`, boots as 8) — but it **probes the bus first** (`device_present` opens the unit's "$" and checks for the no-device timeout): if `<n>` doesn't answer it prints "device `<n>` not present" and *keeps the current device*, so a typo'd unit can't silently misdirect later commands. The tradeoff: you can't pre-assign or name a unit whose drive is powered off (the probe rejects it). An optional name, given for a present unit, is remembered per device number (`device_name[8..15]`) and reused when `device <n>` is given later without one; `reset` (`builtins.c`) reboots via `soft_reset` in `c_io.s` (`jmp ($FFFC)`). `test_util.py` covers peek/poke/reset; `test_device.py` (drive attached, since the probe needs a real device to answer) covers `device` — absent unit reports+stays-put and a present unit names+recalls. The disk commands' own no-device path now reports the unit number too (`report_no_device`).

File commands: `rm <name>`, `mv <old> <new>`, and `cd <path>` all share a `send_command` helper (`fs.c`) that builds `"<prefix><arg1>[=<arg2>]"` and writes it to the drive command channel via `iec_command` (`iec.s`, which shares the LISTEN/name/UNLISTEN path with `iec_open`, just a different secondary: $6F vs $F0|sa). `rm` uses `S0:<name>` to scratch, `mv` uses `R0:<new>=<old>` to rename, `cd` uses `CD:<path>` to navigate -- the 1541 doesn't recognize `CD` (answers ?SYNTAX ERROR), but Meatloaf and other network drives use it; whatever the drive makes of it surfaces on the next `dir`/`pwd`. (The IEC layer folds the name to uppercase as it sends, so case-sensitive URL segments in a Meatloaf path may need a follow-up.) `iec_setname`'s length cap was bumped from 30 to 40 so two 16-char CBM names fit a rename command. `cp <src> <dst>` reads src into user RAM at $0800 and writes it to a new PRG `<dst>,p,w` using the IEC write path: `iec_chkout` (LISTEN + data secondary $60|sa), `iec_putbyte`/`iec_puteoi` (CIOUT data bytes; the last with EOI), `iec_unlisten`. `cat <name>` dumps a file's bytes to the screen; `less <name>` pages it (22 lines, "-- more --", any key continues / `q` quits, each page cleared). Both open a read data channel (SA=2) and stream bytes via `iec_getbyte`. Disk-mutating tests (`test_rm.py`, `test_cp.py`) work on a throwaway copy of the fixture (`_scratch*.d64`, gitignored) made fresh at module import; `cat`/`less` are read-only, so `test_pager.py` reads the tracked fixture's SEQ file `doc` (30 lines, l00..l29) directly. The harness detaches the disk before quitting so VICE flushes writes back to the image (a bare quit can leave a just-written file unclosed -- a "splat"); `make run`/`run.sh` `DISK=` mounts a fresh writable copy so a session never mutates the tracked image.

Config: `border <0-15>` / `bg <0-15>` poke the VIC color registers ($D020/$D021); `text <0-15>` sets the KERNAL text color ($0286) for new output; `prompt <str>` changes the prompt symbol main() shows (a `prompt_str` in `shell.c`, set via `set_prompt`; default ">", always followed by a space) — all in `src/commands/config.c`. `test_config.py` checks the registers and that the prompt changed.

**Deferred — AUTOEXEC:** running commands from an AUTOEXEC file at boot is *not* done. The blocker: doing IEC at boot hangs when the drive isn't cooperating. `iec_sendbyte`'s `@wlisten` now times out (see Phase 6 below), so an *absent* device no longer wedges the send — but VICE's empty drive (no disk) *holds DATA low* when sent an OPEN, so `@wlisten` (which waits for DATA low) passes immediately and the boot can still wedge at the still-unbounded `@wready`/`@ack` waits (and a real 1541 isn't ready for ~1-2s after power-on). Fully unblocking AUTOEXEC needs a drive-ready wait (and/or timeouts on `@wready`/`@ack`) before the OPEN. The status-channel gate idea (read channel 15, proceed only on "00") is sound but can't run until the send can't hang.

Cursor and colors: text is white ($01, set in `reset.s`) on the blue screen. The cursor is a **static** (non-blinking) block: CHROUT clears the reverse-video bit (bit 7) of the cell it's leaving and sets it on the cell it lands on, so the cursor cell is always shown reversed — white block, with any character under it in the blue background colour. No timer/IRQ is involved. `screen_text()` masks bit 7, so the block is invisible to text assertions; `test_cursor.py` reads screen codes / colour RAM directly to check it's a static block and white.

SHIFT support: `scan_keyboard` in `src/irq.s` detects either shift key (`SHFLAG`) and, when held, decodes the found key through a second table `keytab_shift` instead of `keytab`. That table holds the **C64-native** shifted layout: letters fold to uppercase, the number row gives `! " # $ % & ' ( )` (shift-0 stays `0`), the punctuation keys give `< > ? [ ]` (shift-`,` `.` `/` `:` `;`), cursor-right/down become cursor-left/up ($9D/$91), and HOME becomes CLR ($93). Native (not a modern remap) is deliberate: VICE's default *symbolic* keyboard mapping translates a host symbol to the C64 key+shift that natively produces it (host `!` arrives as shift-1, host `&` as shift-6), so the table must decode those back to the same symbol; symbols the C64 makes with a dedicated key (`@ * +`, and the up-arrow for `^`) come through unshifted in `keytab`. One symbol needs the CBM (Commodore) key: VICE maps host `_` to the C64 `@` key + CBM (its only CBM-combined mapping), so `scan_keyboard` also tracks the CBM key — `SHFLAG` is a bitmask now (bit0 shift, bit1 cbm, bit2 ctrl, matching the KERNAL's $028D) — and decodes `@`+CBM to underscore ($5F). **CTRL is a modifier** (not a TAB key as in earlier phases): CTRL+letter emits the ASCII control code ($01-$1A, so ^X=$18, ^K=$0B, and CTRL+I=$09=TAB), which is what the `edit` overlay's nano-style bindings use. Without that, the CBM key (a higher matrix code) won the last-key-wins tiebreak and emitted nothing, so shift-minus produced no underscore. Key repeat: a held key re-emits after `KEY_DELAY` (~0.5s) and then every `KEY_RATE` (~15/s), via an `RPTCNT` countdown in the scan (the new-key path arms the initial delay; the held path counts down and re-emits at the rate). `reset.s` now also clears the keyboard buffer count (`NDX`) and `LSTX` at boot. The matrix *scan* (which key is down, SHIFT, repeat) is GUI-verified (`make run`), since the harness injects into the buffer rather than the matrix — but the decode *tables* are checked directly: `keytab`/`keytab_shift` are `.export`ed, ld65's `-Ln build/labels.txt` records their addresses, and `test_keyboard.py` reads the bytes out of ROM and asserts the entries.

Phase 6 (disk I/O) — done and tested: `src/iec.s` bit-bangs the IEC serial bus on CIA #2 ($DD00) — LISTEN/TALK/secondary/UNLISTEN/UNTALK, `iec_sendbyte` (with EOI), `iec_getbyte`/ACPTR (sets EOI in ST=$90). IRQs are masked per byte. The C side uses a one-arg-at-a-time interface (`src/iec.h`). `src/commands/fs.c` reads the `"$"` directory through shared helpers (`dir_begin`/`dir_line`/`dir_end`, streaming the BASIC-shaped listing one line at a time) used by three commands: `dir` (the full 1541-style listing — block count, quoted name, type, blocks free), `ls` (just the file names: every quoted-name line after the first — the header is skipped positionally, since Meatloaf synthesizes type tokens from filename extensions (TXT, D64, ...) that a whitelist would hide; known CBM types color the name via `TEXT_COLOR`/$0286: PRG green, SEQ cyan, USR yellow, REL red, DEL grey, anything else in the current color; splat `*` prefixes are tolerated). **Holding CTRL pauses `ls`/`dir` output** between lines (the classic slow-scroll key; checked via SHFLAG bit 2, GUI/hardware-verified like the rest of the matrix behavior), and `pwd` (the current device number and remembered name, then the disk name from the header's quoted title, e.g. `9 fd: TEST DISK`). `load <name>` reads a PRG to its load address and reports `loaded $XXXX-$YYYY` -- over the Epyx fast path on a capable drive (probed via M-R $FFFC, cached per device: only a $00,$00 answer -- Meatloaf's emulated memory -- enables it; real-DOS drives keep standard IEC, since the fingerprint install would crash them), falling back to standard IEC otherwise. `ls`/`dir`/`pwd` deliberately stay on **standard IEC** -- the directory is dynamically generated and Meatloaf's Epyx send garbles dynamic content (the GOTD desync), so a fast listing comes back corrupt; `run` starts a loaded program in a real **stock** environment: it plants a CBM80 autostart stub at $CF00 (`run_stub` in `c_io.s`; above the RBCP/overlay RAM and below RAMTAS's $A000 ceiling), points a CBM80 structure at $8000 to it, writes the program's load address and end/VARTAB to $CFF8-$CFFB, and swaps to the stock ROMs via `rbcp_launch_stock` -- the stock reset autostarts the stub. The stub calls IOINIT/**RAMTAS**/RESTOR/CINT (RAMTAS gives BASIC the clean zero page it needs -- our shell leaves cc65 leftovers -- and its non-destructive RAM test preserves the loaded program), then runs a BASIC program ($0801) via init-without-NEW (`$E453`+`$E3BF`, set VARTAB, CLR, `$A7AE` RUN) or machine code via `JMP ($CFF8)`. The stub is validated against the real stock ROMs in `test_runstub.py` (skipped if stock-roms/ is absent). Hardware-only like runstock (the swap is inert in VICE / shell-only builds; `run` then would re-detect the planted CBM80 and loop, so it needs the onerom-stock firmware). Filenames are folded to uppercase (CBM filenames are uppercase PETSCII). No-device gets a "device not present" ($80) timeout; a present-but-silent drive gets a ~1.4s read-timeout ($02) on every CLK wait so a disk-less `ls` prints "read error" instead of wedging. The *send* path is bounded too: `iec_sendbyte`'s first handshake (`@wlisten`, "is a listener there?") waits for DATA via `wait_data_lo` (~0.7s) and sets $80 on timeout — so targeting a device number that isn't on the bus (e.g. `device 9` when only 8 is present) reports "device `<n>` not present" instead of hanging forever, even though the present drive ack's the absent device's command bytes under ATN (the absent device only reveals itself once ATN is released and nobody listens for the name). This is exactly what lets `device <n>` probe-before-switch (above). The remaining send waits (`@wready`/`@eoiack`/`@ack`) stay unbounded so a busy-but-present drive (mid-seek) isn't falsely abandoned. On that send-timeout `send_listen` bails through `@fail`, which broadcasts UNLISTEN+UNTALK (which the present drive acknowledges) so it returns to idle and the next command to the real device works (`test_device.py::test_absent_device_reports_and_stays_put`). Tested against **true drive emulation** (mandatory — our replaced KERNAL means VICE's virtual-device traps never fire): `test/data/test.d64` (regen via `make_test_disk.sh`; its `prog` prints "hello from prog" and RTSes) mounts via `Vice(disk=...)`/`VICE_DISK`; tests poll until transfers finish; `test_run.py` checks `run` prints and then the shell regains the prompt.

Phase 6 leftovers (when resumed): the shell's `cd` is wired (drive-side; see File commands above) and the formal KERNAL file entry points landed at the start of Phase 9 (see the "KERNAL entry points" section above and `test_kernal_io.py`). Known limit: a `load` overlapping the shell's working RAM ($C000-$CFFF) would corrupt the loader mid-load (the test program loads at $2000 to stay clear).

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
