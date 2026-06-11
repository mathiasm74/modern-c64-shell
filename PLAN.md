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

## Phase 9: Software compatibility testing

**Goal:** Systematically verify what real-world software needs from the ROMs, and discover what (if anything) our shell ROM is missing. Because we omit BASIC entirely and may trim the KERNAL, some software will break. This phase finds out what, why, and whether it's fixable.

**Why this matters:** Our shell deliberately drops BASIC and possibly trims KERNAL features (tape, some vectors). Lots of software assumes the full stock environment: it calls undocumented KERNAL entry points, reads specific ROM bytes directly, copies ROM routines into RAM, depends on BASIC zero-page variables being initialized, or expects the BASIC ROM to be present at $A000-$BFFF even if it never calls it. We need to catalogue these dependencies empirically rather than guess.

**Test methodology:** Build a test matrix of software categories and run each in VICE (with our ROM) and on real hardware, recording pass/fail/partial and the failure mode. Automate as much as possible via the VICE test harness; some will need manual observation.

**Categories to test (roughly in order of likely compatibility):**
- *Pure machine-language games* (cartridge-style, self-contained): should mostly work. These set up their own environment and rarely touch BASIC. Examples: most demoscene productions, cartridge game conversions, intros.
- *Disk-loaded ML games with their own loaders:* test the interaction between our fast loader / KERNAL LOAD and the game's loader. Many games install custom IRQ handlers and custom loaders; watch for conflicts with ours.
- *Games that use KERNAL LOAD then take over:* these rely on a correct KERNAL load path. Verify our LOAD matches stock behavior closely enough (correct end-address reporting, correct status flags, correct handling of load address).
- *Multi-load games* (load levels/data during play): stress the KERNAL file I/O routines repeatedly. Watch for state that stock KERNAL maintains that we don't.
- *Utilities and tools* (ML monitors, copiers, disk tools): often poke deep into KERNAL internals or copy ROM routines. High risk of depending on exact ROM contents.
- *Demos:* frequently abuse undocumented behavior, exact cycle timing, and direct ROM reads. The hardest compatibility target; failures here are informative even if we choose not to fix them.
- *BASIC programs:* expected to fail (no BASIC). Document this clearly. Test a few anyway to confirm the failure mode is graceful (clear error, not a crash/hang) and to see whether anything partially works.
- *BASIC programs with ML components* (hybrid type-ins): confirm failure mode. Note whether the ML portion could theoretically run if loaded differently.
- *Productivity software* (word processors, spreadsheets): many are ML-based and may work; some embed or require BASIC. Test representative examples.

**Tasks:**
- Assemble a corpus of test software covering the categories above. Use freely distributable / homebrew / PD software where possible to keep the corpus shareable. Do not commit copyrighted ROMs or commercial game images to the repo; keep a local-only test corpus and document its contents in a manifest.
- For each title, define a minimal "did it work" check: does it reach its title screen / main loop, does it accept input, does it load subsequent data. Automate via VICE where the check can be expressed as a screen-memory or PC assertion.
- Record results in a compatibility matrix (`docs/COMPATIBILITY.md`): title, category, VICE result, hardware result, failure mode, root cause if known, fixable (yes/no/maybe).
- For each failure, diagnose the root cause:
  - Does it call a KERNAL entry point we didn't implement or stubbed incorrectly?
  - Does it read a specific ROM byte (e.g. for a version check, or to copy a routine)?
  - Does it depend on BASIC being present at $A000-$BFFF (even passively)?
  - Does it depend on BASIC zero-page initialization ($00-$8F)?
  - Does it depend on KERNAL zero-page / page-2/3 variables we don't set up?
  - Is it a timing issue (our fast loader or IRQ handler)?
- Use OneROM telemetry (SWD) on real hardware to capture exactly which ROM addresses failing software reads. This is the killer feature for this phase: you can see precisely what byte a program expected to find and didn't. Log the access pattern leading up to a crash and work backwards.
- Categorize fixes:
  - *Cheap fixes:* missing KERNAL entry point, wrong status flag, a ROM byte that some software reads for a version/identity check that we can simply replicate at the same address. Add these to our ROM.
  - *BASIC-presence fixes:* software that needs some bytes at $A000-$BFFF. Consider whether a small BASIC-compatibility shim (key entry points and identity bytes, not a full interpreter) buys meaningful compatibility cheaply. Decide case by case; do not let this balloon into reimplementing BASIC.
  - *Won't-fix:* software fundamentally requiring full BASIC, or abusing exact ROM contents/timing in ways incompatible with our design. Document and move on. These users switch to a stock-BASIC OneROM slot.
- Where a cheap fix exists, implement it and add a regression test so the compatibility matrix stays green.
- Identify the set of KERNAL entry points and ROM identity bytes that, if present, maximize compatibility for minimum ROM cost. This is the key deliverable: an evidence-based answer to "what's the minimum we must keep to run most ML software."

**Done when:**
- `docs/COMPATIBILITY.md` exists with results for at least ~20-30 representative titles across the categories.
- Every failure has a documented root cause (or "undiagnosed" explicitly noted).
- All cheap fixes are implemented and covered by regression tests.
- There is a clear, evidence-based statement of the shell ROM's compatibility profile: "runs self-contained ML software and KERNAL-LOAD games; does not run BASIC programs or software requiring [specific list]."
- Known incompatibilities and the "switch to BASIC slot" guidance are documented for users.

**Risks/notes:**
- Scope can explode; cap the corpus size and prioritize representative titles over exhaustive coverage. Twenty well-chosen titles teach more than a hundred random ones.
- Resist the urge to chase every demo. Demos are the hardest target and often not worth fixing; treat them as informative stress tests, not compatibility requirements.
- Do not commit copyrighted images to the repo. Keep the corpus local; commit only the manifest, results, and any PD/homebrew test programs you have the right to distribute.
- The OneROM telemetry workflow is worth setting up properly here even if you skipped it earlier; "show me exactly which ROM address this program read right before it died" turns guesswork into a five-minute diagnosis.
- Some "incompatibilities" will actually be fast-loader bugs from Phase 7 surfacing under real workloads. Keep Phase 7's tests in mind when diagnosing.

---

## Phase 10: Real hardware validation

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

## Backlog / next up (post-hardware bring-up)

Concrete follow-ups from the fast-loader + boot-selector hardware bring-up
(Phase 7/10). Ordered by leverage and dependency. **RBCP is the keystone** --
the boot selector, the Phase-9 stock handoff, the `basic`/Simons' swap, and
likely the lazy-load overlays all ride on it.

### 1. RBCP ROM-swap validation

**Goal:** `runstock` and the C= boot selector actually switch the One ROM to the
stock ROMs on real hardware (the swap currently never engages).

**What's known:** the C= detection works (reset.s reads keyboard col PA7 / row
PB5); the host->plugin RBCP handshake doesn't complete. The host-control
plugin's `command_page` defaults to 0 and only processes reads on the page it
watches. Our `rbcp_config.s` uses command page `$EE` / back-channel `$EF00`;
Holger Gryska's proven c64-bootloader uses `$E0` / `$E100`. Our regions also sit
on top of our KERNAL code.

**Tasks:**
- Relocate the RBCP command page + 1 KB back-channel into the KERNAL ROM's free
  `$F2D1-$FC84` block, with controlled progress/response bytes.
- Reconcile the knock / command-page bootstrap with the plugin (confirm whether
  the host configures the page via `enter_cmd_resp` or must match a default).
- Iterate on hardware (`make onerom-stock-flash`); expect several rounds.

**Done when:** holding C= at boot -> stock C64 `READY.`, and `runstock` from the
shell does the same. Unblocks everything below + Phase 9.

### 2. `basic` command -> Simons' BASIC

**Goal:** a `basic` command (and/or a boot-menu entry) that swaps to Simons'
BASIC.

**Notes:** Simons' BASIC is a 16 KB autostart cartridge (`$8000-$BFFF`) riding on
the stock KERNAL/BASIC, so it's another One ROM slot (Simons' cart + stock ROMs)
and a swap to it -- essentially `runstock` with a different target slot. User
supplies the Simons' ROM (gitignored, like `stock-roms/`). **Depends on #1.**

### 3. Fast-loader -> `load` integration & polish

**Goal:** make the fast path automatic and safe.

**Tasks:**
- Fold `fload` into `load`: try the Epyx fast path, fall back to standard IEC if
  the drive doesn't engage (so a non-Epyx drive isn't handed a stray M-E $01A9).
- Use `default_device` instead of the hardcoded device 8.
- Decide whether `fload` stays as an explicit command too.

### 4. Lazy-load + cache command overlays

**Goal:** break past the 8+8 KB ceiling -- keep core commands resident, store
extra command code in additional One ROM flash slots, and load + cache each
command's code into C64 RAM on first use.

**Design spike first (not yet a buildable task):**
- How to pull a command's bytes from an extra flash slot into C64 RAM: is there a
  fast RBCP "read N bytes from slot X" path, or only the byte-at-a-time NV-peek?
  If neither, fall back to whole-bank swap via a RAM trampoline.
- Dispatch table grows a per-command location (resident vs slot+offset).
- RAM cache region + eviction policy.
- Relocatable command code, or fixed per-command load addresses (cc65 overlays).

Almost certainly rides on RBCP (#1).

### 5. Fast-loader reliability for large / network files

**Goal:** fix or characterize the GOTD desync (a large dynamic Meatloaf link ends
at random addresses; small local files are reliable).

**Notes:** the error-rate math points at network/dynamic streaming, not size. The
first real step needs a clean **large-local** test -- blocked on getting a file
onto Meatloaf (an SD card). May end up documented as a Meatloaf limit.

### Already in the plan, re-rank as you like

AUTOEXEC (deferred, Phase 8) · broader drive testing -- real 1541 fast-load
fallback, SD2IEC (Phase 10) · software-compat corpus + stock handoff (Phase 9,
depends on #1) · release packaging / tagging (Phase 10 done-when).

---

## Beyond Phase 10

Possible directions if you want to keep going:

- **Networking:** drivers for RR-Net, WiFi modems, or Ultimate's modem emulation. `telnet`, `wget`, `irc` commands.
- **Scripting:** a small embedded language for shell scripts (something Lua-like but smaller, or a Forth).
- **80-column mode:** software 80-column or use the VDC if running on a C128.
- **Filesystem abstraction:** a virtual filesystem that unifies multiple devices into a tree.
- **Multi-user history:** persistent history across reboots, stored on device 8.
- **Community release:** package as a downloadable ROM image with documentation, ship to lemon64 / forum64 / GitHub for feedback.

These are all out of scope for the initial project but worth keeping in mind as you design earlier phases. Avoid choices that make these impossible later.
