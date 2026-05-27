# Project Plan: C64 Shell ROM

This document defines the phased plan for building the C64 shell ROM. Each phase produces a testable deliverable. Phases build on each other, so don't skip ahead.

When working on a phase:
- Read this document and `CLAUDE.md` first.
- Each phase has a clear success criterion ("Done when..."). The phase isn't complete until that criterion is met.
- Add tests for every new feature. The test suite is the safety net.
- Update `CLAUDE.md` if you introduce new conventions, file layouts, or memory regions.
- Commit after every passing test, with a short imperative subject line.

---

## Phase 0: Toolchain setup

**Goal:** Produce two 8KB binaries from a trivial source tree, verify VICE boots them, have `make test` pass a smoke test.

**Tasks:**
- Verify cc65, VICE, Python 3, and Make are installed and on PATH.
- Create the directory structure from `CLAUDE.md`.
- Write `cfg/rom.cfg` with two output segments (basic at $A000-$BFFF, kernal at $E000-$FFFF) and standard 6502 vectors in the kernal segment.
- Write `src/reset.s` with a minimal reset routine that sets stack pointer, sets border/background colors, writes "HELLO" to screen RAM at $0400, and infinite-loops.
- Write a stub IRQ handler that just RTIs.
- Wire reset, IRQ, and NMI vectors.
- Write `Makefile` with `all`, `clean`, `check-tools`, `run`, `test` targets.
- Write `test/smoke_test.py` that launches VICE headless, reads screen memory, asserts "HELLO" is present.

**Done when:**
- `make test` exits 0.
- `make run` launches VICE and shows "HELLO" on a blue background with black border.
- The 16KB total ROM image can be produced by concatenating `build/basic.bin + build/kernal.bin`.

**Risks/notes:**
- VICE's remote monitor port and protocol vary by version. Use the text monitor over TCP for the first cut; binary monitor is a later optimization.
- On macOS, VICE may need `-default` to skip user config. On Linux, headless operation may need `-console` or `-display none`.

---

## Phase 1: Minimum viable boot

**Goal:** Take full control of boot. Initialize the machine to a clean, known state under our control rather than relying on stock KERNAL behavior.

**Tasks:**
- Expand `src/reset.s` to perform proper hardware init:
  - Disable interrupts (`SEI`), set decimal mode off (`CLD`), set stack pointer.
  - Initialize VIC-II registers: set screen RAM at $0400, character ROM at $1000, blank screen during init, then enable.
  - Clear screen RAM ($0400-$07E7) with spaces (PETSCII $20).
  - Clear color RAM ($D800-$DBE7) with light blue (default text color).
  - Set border ($D020) and background ($D021) colors.
  - Initialize CIA #1 and CIA #2 to known-safe states (timers stopped, interrupts masked).
  - Configure the processor port at $01 to map RAM at $A000-$BFFF and ROM at $E000-$FFFF.
- Display a startup banner: project name, version, "ready" message on screen.
- Still no input, still no IRQs enabled. Just a clean, deterministic boot to a static screen.

**Done when:**
- VICE boots to a screen showing your banner text on a clean background.
- The machine state is reproducible: identical every boot.
- Test asserts the banner text appears in screen memory at the expected position.

**Risks/notes:**
- The processor port at $01 controls memory banking. Get this wrong and you can map yourself out of existence. Standard value for "RAM + KERNAL ROM + I/O" is $37.
- VIC-II init order matters; setting the screen pointer before clearing screen RAM can show garbage briefly.

---

## Phase 2: Test harness

**Goal:** Solidify the automated test loop. This phase is infrastructure, not features.

**Tasks:**
- Refactor `test/smoke_test.py` into a reusable library: `test/lib/vice.py` with classes for launching VICE, connecting to the monitor, reading/writing memory, injecting keystrokes, taking screenshots, and shutting down cleanly.
- Add helpers for common assertions: `assert_screen_contains(text)`, `assert_memory_equals(addr, bytes)`, `assert_pc_at(addr)`.
- Add screen-code-to-ASCII decoding helper.
- Add keyboard injection helper (writes to the keyboard buffer at $0277 and updates $C6).
- Write a real test runner: discover `test_*.py` files, run each, report pass/fail summary.
- Add `make test-verbose` that shows VICE output for debugging.
- Add a CI-friendly mode that runs without any display (`-display null` or equivalent).

**Done when:**
- The test harness is a library, not a script.
- At least three smoke tests pass: boot succeeds, banner displays, memory at known addresses contains expected values.
- Total test runtime is under 30 seconds.

**Risks/notes:**
- VICE startup time dominates test runtime. Consider keeping a single VICE instance alive across tests if it becomes painful, but only after the simple approach proves too slow.

---

## Phase 3: Keyboard input and basic I/O

**Goal:** Make the machine interactive. Implement IRQ handler, CHROUT, GETIN, and an echo loop.

**Tasks:**
- Write `src/irq.s` with a proper IRQ handler:
  - Save A, X, Y on stack.
  - Acknowledge CIA #1 timer A interrupt (read $DC0D).
  - Call keyboard scan routine.
  - Increment the jiffy clock at $A0-$A2.
  - Restore registers, RTI.
- Implement keyboard scan in assembly. Read CIA #1 ports, decode the matrix, push results to keyboard buffer at $0277-$0280, update buffer count at $C6.
- Initialize CIA #1 timer A for 60Hz (NTSC) or 50Hz (PAL) IRQ rate.
- Write `src/screen.s` containing CHROUT logic:
  - Track cursor position at known zero-page locations.
  - Handle printable characters: write to screen RAM and color RAM, advance cursor.
  - Handle control characters: CR ($0D), backspace ($14), clear screen ($93), home ($13).
  - Implement scroll when cursor goes past the bottom row.
- Wire up the CHROUT entry point at $FFD2 in `src/kernal_stubs.s` (JMP to implementation).
- Wire up the GETIN entry point at $FFE4 (reads from keyboard buffer, returns 0 if empty).
- Update `src/reset.s` to enable interrupts (`CLI`) after init and enter an echo loop: GETIN, if nonzero CHROUT it, repeat.

**Done when:**
- VICE boots, you can type, characters appear on screen.
- Backspace, return, and clear screen all work.
- The screen scrolls correctly when you fill it.
- A test injects a string via the keyboard buffer and asserts it appears on screen.

**Risks/notes:**
- Keyboard matrix decoding is fiddly. The Programmer's Reference Guide has the matrix layout; copy it carefully.
- Don't forget to acknowledge the CIA interrupt or you'll loop forever in the IRQ handler.
- The cursor blink can wait until polish phase; just show a static cursor or none for now.

---

## Phase 4: Switch to cc65 for the shell

**Goal:** Move shell logic into C. Establish the C-to-assembly interface.

**Tasks:**
- Update `cfg/rom.cfg` to support cc65 output: define CODE, RODATA, DATA, BSS, ZEROPAGE segments. The cc65 docs have a ROM target example to adapt.
- Configure cc65's zero-page usage: cc65 needs some zero-page for its pseudo-registers and software stack. Allocate $02-$1F or similar; keep $A0-$A2 for jiffy clock and $C6/$0277-$0280 for keyboard.
- Write a minimal `src/shell.c`:
  - `void main(void)` that prints a prompt, reads a line, echoes "command not found: <line>", loops.
  - Use cc65's `conio.h` (`cputs`, `cgetc`) or direct calls to CHROUT/GETIN. Start with `conio.h` for simplicity.
- Wire `_main` into the reset routine: after hardware init, JSR `_main`.
- Update the build to compile C files with cc65, assemble with ca65, link all together.
- Verify the final ROM still fits in 16KB. Track size in `make` output.

**Done when:**
- Booting drops to a working prompt.
- You can type a line, press return, see the "command not found" response.
- The shell loops indefinitely.
- A test injects a line, reads the response, asserts correctness.

**Risks/notes:**
- cc65's default linker config assumes a normal C64 with BASIC and KERNAL available. You need a custom config; don't use `c64-asm.cfg` or `c64.cfg` directly.
- cc65 generates code that uses a software stack at $0100 plus a separate "data stack" pointed to by zero-page registers. Make sure the data stack pointer is initialized before calling `_main`.
- Watch ROM size carefully. cc65's standard library is large; link only what you use.

---

## Phase 5: Command parser and built-ins

**Goal:** Make the shell actually shell-like. Tokenize input, dispatch to commands, implement trivial built-ins.

**Tasks:**
- Write `src/parser.c`:
  - Tokenize input: split on whitespace, handle quoted strings.
  - Return a struct with command name and argv-style argument array.
- Define a command table in `src/shell.c`: array of `{name, handler}` pairs. Handler signature: `void cmd_xxx(int argc, char *argv[])`.
- Implement built-ins in `src/commands/builtins.c`:
  - `help` — lists all available commands.
  - `clear` — clears the screen (CHROUT $93).
  - `echo <args>` — prints arguments separated by spaces.
  - `ver` — prints project name and version.
  - `exit` — for now, just prints "nothing to exit to".
- Modify the shell loop to call the parser, look up the command, dispatch.
- Handle unknown commands gracefully ("command not found").
- Handle empty input (just return to prompt).

**Done when:**
- All five built-ins work and have tests.
- `help` lists all commands dynamically (reading the dispatch table).
- The parser handles edge cases: leading/trailing whitespace, multiple spaces, empty input, very long input (truncate gracefully).

**Risks/notes:**
- Decide on the input buffer size early (80 chars is reasonable for a 40-column display with line wrapping).
- The command table can live in ROM (RODATA segment).

---

## Phase 6: Disk I/O

**Goal:** Read and write files on IEC devices. Implement `ls`, `load`, `run`.

**Tasks:**
- Implement KERNAL entry points for file I/O in `src/kernal_stubs.s` and their implementations:
  - `SETLFS` ($FFBA) — set logical file, device, secondary address.
  - `SETNAM` ($FFBD) — set filename pointer and length.
  - `OPEN` ($FFC0) — open file using current SETLFS/SETNAM state.
  - `CLOSE` ($FFC3) — close logical file.
  - `CHKIN` ($FFC6) / `CHKOUT` ($FFC9) — set current input/output channel.
  - `CLRCHN` ($FFCC) — restore default channels (keyboard/screen).
  - `CHRIN` ($FFCF) — read character from current input channel.
  - `LOAD` ($FFD5) — load file, with secondary address determining load-to-address behavior.
- These can be adapted from the public domain reimplementations of the original KERNAL.
- Implement `cmd_ls` in `src/commands/fs.c`:
  - SETLFS 1, 8, 0; SETNAM "$"; OPEN; CHKIN 1; read and print bytes (parsing BASIC-style directory listing); CLOSE.
- Implement `cmd_load <filename>`:
  - SETLFS 1, 8, 1; SETNAM filename; LOAD 0 (load to address from file).
  - Print "loaded $XXXX-$YYYY" on success.
  - Track the load address range in a known location for `run`.
- Implement `cmd_run`:
  - JMP to the start address of the most recently loaded program.
  - For SYS-startable programs, this is usually the load address itself, but some programs need a specific entry point. For Phase 6, just JMP to load address.
- Implement `cmd_cd <path>` for SD2IEC/Meatloaf: sends "CD:path" command to the drive (channel 15).

**Done when:**
- `ls` lists a directory.
- `load filename` loads a program.
- `run` executes it.
- `cd` navigates directories on SD2IEC (test in VICE with FS device emulation).
- Tests cover each command with a known D64 image mounted.

**Risks/notes:**
- The KERNAL routines are tightly intertwined; implementing them piecemeal is hard. Consider porting them together as a unit from a known reference implementation.
- VICE's true drive emulation must be enabled for realistic disk behavior. Add `-truedrive` to test command lines.
- Some commands assume device 8; consider making the default device configurable later.

---

## Phase 7: Fast loader integration

**Goal:** Loading is visibly faster than stock IEC. Epyx-compatible protocol.

**Tasks:**
- Study Sven Petersen's open-source Epyx FastLoad rebuild on GitHub for the protocol details.
- Write `src/fastload.s` implementing the Epyx fast loader:
  - Detect compatible drive (probe with the Epyx initialization sequence).
  - Upload the drive-side fast loader code to the 1541's RAM via M-W commands.
  - Patch into LOAD to use the fast protocol when a compatible drive is present.
  - Fall back to standard IEC when not.
- Add a `fastload` command that displays current fast loader state and lets the user enable/disable.
- Add a startup detection that probes for fast-loader-compatible drives and auto-enables.

**Done when:**
- Loading a 30KB program takes noticeably less time in VICE (with true drive emulation) when fast loader is active vs. when it's disabled.
- Tests time the load with and without fast loader and assert a ratio.
- Falls back gracefully if the drive doesn't support the protocol.

**Risks/notes:**
- This is the hardest phase. Budget two to three times longer than you think.
- Timing in VICE with true drive emulation is close enough to real hardware that bugs caught here will likely matter on hardware too.
- Consider supporting JiffyDOS protocol detection too (it's well-documented), but don't reimplement JiffyDOS itself (licensed).
- This phase is a good candidate for the "ask me before assuming" workflow with Claude Code; protocol details are subtle.

---

## Phase 8: Polish and persistence

**Goal:** Make the shell pleasant to use daily.

**Tasks:**
- Line editing: left/right arrow keys move within current line. Insert and overwrite modes.
- Command history: up/down arrows recall previous commands. Store last N commands in RAM at a reserved location.
- Tab completion: TAB completes the current word against the command table (first word) or filenames (subsequent words; requires reading directory).
- Cursor blink: timer-driven, toggle character at cursor position with reverse video.
- Startup config: on boot, try to load and execute `AUTOEXEC` from device 8. Each line is a command to run.
- Additional commands:
  - `cp src dst` — file copy.
  - `rm filename` — delete file.
  - `mount image.d64` — mount a disk image (SD2IEC/Meatloaf).
  - `unmount` — unmount.
  - `peek $addr` — read byte from memory.
  - `poke $addr $val` — write byte to memory.
  - `mon` — drop into a machine language monitor (separate implementation, possibly large; budget carefully).
  - `device <n>` — change default device number.
  - `reset` — soft reset (JMP $FCE2).
- Configuration:
  - Allow custom colors (border, background, text) via a config file or commands.
  - Allow setting a custom prompt string.

**Done when:**
- Daily use feels natural.
- All listed commands work and have tests.
- Total ROM size still fits in 16KB.
- The shell handles error conditions without crashing (drive not present, file not found, out of memory, etc.).

**Risks/notes:**
- The machine language monitor is genuinely large (1-2KB) and may push you over budget. Consider making it optional or loading it from disk on demand.
- Polish is open-ended. Set a deadline or this phase consumes the project.

---

## Phase 9: Real hardware validation

**Goal:** Ship a ROM that works on real C64s.

**Tasks:**
- Flash the ROM to a OneROM or EPROM.
- Install in a real C64 (PAL and NTSC if both available).
- Test with real hardware:
  - Real 1541 (slow IEC, fast loader fallback path).
  - SD2IEC.
  - Meatloaf.
  - 1541 Ultimate II+ or similar.
- Verify fast loader timing on real hardware. Expect to find at least one timing bug VICE missed.
- Test with a variety of software to verify KERNAL compatibility: known-good machine language games and utilities.
- Document any known incompatibilities.

**Done when:**
- The ROM boots on real hardware and behaves identically to VICE.
- Fast loader works with at least two different drive types.
- A "release" build is tagged in git and an annotated release notes document exists.

**Risks/notes:**
- Real hardware has analog reality VICE doesn't model: capacitance, slightly different clock speeds, marginal ICs. Expect surprises.
- Have a stock KERNAL EPROM ready to swap back if things go badly.
- The OneROM's switching mechanism should let you keep a known-good ROM in another slot as a safety net.

---

## Beyond Phase 9

Possible directions if you want to keep going:

- **Networking:** drivers for RR-Net, WiFi modems, or Ultimate's modem emulation. `telnet`, `wget`, `irc` commands.
- **Scripting:** a small embedded language for shell scripts (something Lua-like but smaller, or a Forth).
- **80-column mode:** software 80-column or use the VDC if running on a C128.
- **Filesystem abstraction:** a virtual filesystem that unifies multiple devices into a tree.
- **Multi-user history:** persistent history across reboots, stored on device 8.
- **Community release:** package as a downloadable ROM image with documentation, ship to lemon64 / forum64 / GitHub for feedback.

These are all out of scope for the initial project but worth keeping in mind as you design earlier phases. Avoid choices that make these impossible later.
