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

### 3. Fast-loader -> `load` integration & polish -- DONE (2026-06-13, v0.19)

`load` rides the Epyx fast path automatically on a capable drive and falls
back to standard IEC otherwise; `fload` stays as the explicit/diagnostic
form; both use default_device. Safety probe: M-R of the drive reset vector
($FFFC), cached per device -- real-DOS drives (1541 family, JiffyDOS, Pi1541)
answer their ROM vector and never receive the fingerprint install (M-E on a
real drive would execute our fake bytes); Meatloaf's zero-initialized
emulated memory answers $00,$00, the only answer that enables the fast path.

Fast directory listings were tried (v0.18) and reverted (v0.19): the
directory is generated on the fly, and Meatloaf's Epyx send corrupts
dynamically-generated content (the same desync as a dynamic `fload` link --
see #5 / docs), so a fast listing came back garbled on hardware. `ls`/`dir`/
`pwd` stay on standard IEC -- slow but correct. A fast static-file `load` is
clean because the file bytes already exist; only on-the-fly content desyncs.
A reliable fast directory would need either a checksum/retry layer or an
upstream Meatloaf fix (issue #45 territory).

The Phase-7b/7c drive-blob scaffolding and the tardis PoC command were
evicted to make ROM room (both ROM halves were full).

### 4. Lazy-load + cache command overlays (the "tardis")

**Goal:** break past the 8+8 KB ceiling -- keep core commands resident, store
extra command code in One ROM flash slots, and load + cache each command's code
on first use. Also relieves the (full) BASIC ROM: fat residents (`help` text,
`mon`, `less`) can move into overlays.

**Design spike DONE (2026-06-12).** The mechanism was verified by reading the
host-control plugin source and the RBCP defs; it's better than hoped -- block
transport straight into executable ROM space, not byte-at-a-time pokes.

**The mechanism (hot-modifying the active ROM):**
- `SLOT_PEEK` (GRP_READ $07, device side implements it): args = count (0=256),
  24-bit offset, source RAM slot. The device copies up to 256 bytes from any
  RAM slot's image **into the back-channel data section of the ACTIVE slot** --
  i.e. they appear in our live KERNAL ROM at the back-channel data address
  (now $FE08 -- see rbcp_config.s), readable/executable as
  ordinary ROM. One sub-millisecond command moves 256 bytes (a command's args
  ride in the low address byte of single command-page reads, ~10 cycles/byte;
  a 2 KB overlay is 8 peeks -- imperceptible at the prompt).
- Peeked bytes PERSIST after `EXIT_CMD_RESP` (the exit handler only clears the
  session flag; nothing restores the original ROM bytes), so the window stays
  valid after leaving command mode.
- `SLOT_PEEK` reads from a **RAM slot**, not flash: `LOAD_SLOT` the overlay
  library (flash -> RAM slot 1) once per boot, lazily; peeks are cheap after.
- `SLOT_POKE` (1 byte/command) exists too -- right for hot-patching, too slow
  for bulk. `SLOT_POKE_ALL_BYTE` fills.

**Placement: can overlay bytes land anywhere in the ROM?**
- Via `SLOT_PEEK`: no. The handler always deposits into the back-channel data
  section of the active slot, starting at data offset 0 (each peek overwrites
  from the start -- two peeks can't be appended to build a longer run). Net:
  <=256 bytes, always at the back-channel data address ($FE08).
- Via `SLOT_POKE`: yes, anywhere (24-bit offset) -- but at ~one byte per
  command it's two orders of magnitude slower than peek (~1 KB in tenths of a
  second vs milliseconds). Patch tool, not a transport.
- Loophole for later: the back-channel location is a HOST argument to
  `ENTER_CMD_RESP`, so the loader can re-knock with a different base and make
  peeks land elsewhere -- in effect 256-byte pages placeable at any 4-byte-
  aligned spot, paying a re-knock plus an 8-byte trampled header per location.
  That would allow several overlay routines resident in ROM at different
  addresses (paging across the $F6xx-$FBxx free run). Hard limits: whatever a
  window covers is sacrificed (the device never restores the original bytes),
  so only free-fill regions qualify -- never live code, never the $E0xx
  command page -- and code must be linked for the specific window address.
  Kept in the back pocket; the RAM-cache design below stays primary because
  RAM placement is free-form and unlimited-size without these gymnastics.

**Architecture:**
- Build: each overlay command is its own cc65 module linked at a fixed cache
  address; Makefile packs them into `overlays.bin` (a pseudo-ROM chip_set in
  `cfg/onerom-stock.json`) + a generated directory (offset/size per command)
  compiled into the resident dispatch table.
- Resident loader (small, KERNAL ROM): dispatch table gains resident-vs-
  {offset,size} per command. On miss: SEI -> knock/enter CR -> (LOAD_SLOT once
  per boot) -> SLOT_PEEK loop -> copy each 256-byte chunk from the window to the RAM
  cache -> exit CR -> CLI -> call. One-entry cache (remember which command is
  loaded) makes repeats free.
- Execution home: start RAM-cache-only (~2 KB around $C800, where the RBCP
  trampoline already transiently lives) -- one mechanism, any size. Tiny
  (<=256 B) commands could later run straight out of the back-channel window
  (zero RAM cost) if RAM gets precious.

**Capacity:** each flash chip_set holds a 16 KB library and the device takes
many slots -- effectively as much command code as the flash holds.

**Caveats (all manageable):**
- In CR mode every read of $E000-$E0FF is command traffic: loader runs with
  IRQs masked and must not fetch from that page (it lives in upper KERNAL ROM).
- RAM slot 1 is shared with the stock-swap target -- harmless (swapping to
  stock means leaving the shell); reload lazily after.
- Our vendored host lib predates `SLOT_PEEK` (plugin has it, v0.1.0 defs
  don't) -- add it ourselves, ~20 lines mirroring an existing GRP_READ command.
- Hardware-validated only (VICE doesn't model the One ROM), but it sits on the
  now-proven RBCP layer -- incremental, not blind.

**Proof of concept DONE (2026-06-12, v0.10, hardware-verified).** The `tardis`
command (`cmd_tardis` in mem.c + `_rbcp_poc_peek` in launch.s) SLOT_PEEKs 64
bytes from RAM slot 0 (our own image) into the back-channel window and compares:
on the real One ROM it printed `matches kernal ($e000)` -- the transport works,
peeked bytes are readable in the window after exiting command mode, and **slot
images are kernal-half-first** (offset 0 = kernal byte 0, basic at +$2000), so
overlay-library offsets need no translation. The lib additions
(`rbcp_cmd_slot_peek`, `rbcp_cmd_exit_cmd_resp`, `rbcp_copy_to_ram`) are the
building blocks the real loader will reuse.

**Overlay loader DONE (2026-06-12, v0.11, hardware-verified).** `about` is the
first shell command whose code is not in the 16KB ROM: src/overlays/about.s ->
256-byte page in build/overlays.bin (8KB chip_set, loadable ROM set 2) ->
fetched on first use by `_overlay_fetch_page` (enter CR, LOAD_SLOT overlays ->
RAM slot 1, SLOT_PEEK page, copy to the $CE00 cache, exit) -> called via the
thunk in src/commands/overlay.c, which caches the page number (repeat calls
skip the device). First call is imperceptibly slower than resident; repeats
indistinguishable. Adding a command = drop a module in src/overlays/, append
to OVERLAYS in the Makefile (position = page number), add a thunk.

**Multi-page C overlays DONE (2026-06-12, v0.12): the `edit` command.** A
nano-like full-screen editor (~4.6KB, 18 pages -- nearly a third of the shell
ROM's total size) living entirely in the overlay slot: gap-buffer text editing
of 30KB documents at $0800-$7FFF, line-based cut/copy/paste (^K/^C/^U with
nano's chain-append), save/load of SEQ files via the fixed KERNAL entry
points, ^O save (with @0: replace), ^X exit with save prompt. Infrastructure
that came with it: cc65 C overlays linked standalone at $8800 (own zeropage
$40-$5F + own C stack, crt0 header with cache-validation magic + page count),
`_overlay_fetch_multi` (N pages, one RBCP session, mailbox-parameterized),
CTRL as a real keyboard modifier (SHFLAG bit2, CTRL+letter -> control codes),
and KERNAL CHROUT now routing to IEC after CHKOUT with stock-style one-byte
deferral so CLRCHN flushes the last byte with EOI. The editor is fully
VICE-tested by pre-seeding the cache (test_edit.py); the fetch transport is
the hardware-proven path `about` uses.

**Editor polish (reported from hardware use):** typing flickers and feels a
bit slow -- the editor does a full 23-row redraw on every keystroke. Fix:
dirty-row rendering (plain inserts redraw only the current line; full redraw
only on scroll/structural changes), already anticipated in the design.

**Remaining for the full tardis vision:**
- Generated directory (offset/size per command) once overlay count grows --
  today page numbers are positional constants (about=0, edit=1..18).
- A shell API jump table at a fixed ROM address would widen what overlays can
  reach beyond the KERNAL entries (e.g. default_device instead of device 8).
- Migrate fat residents (help text, future mon/less growth) to overlays to
  relieve the full BASIC ROM -- note migrated commands become hardware-only
  unless their VICE tests pre-seed the cache page + tag.

### 5. Fast-loader reliability for large / network files

**Root cause analysis (2026-06-13): see `docs/EPYX-RECEIVER.md`.** The user's real Epyx cart loads GOTD from the Meatloaf fine, so the send is correct -- our receiver is marginal on dynamic content (the Meatloaf's ESP32 watchdog interrupts jitter the per-byte detect latency, pushing our fixed-offset samples out of the window). Top candidate: buffer the directory then parse, so fast `ls`/`dir` uses the tight receive loop.

**Goal:** fix or characterize the GOTD desync (a large dynamic Meatloaf link ends
at random addresses; small local files are reliable).

**Notes:** the error-rate math points at network/dynamic streaming, not size. The
first real step needs a clean **large-local** test -- blocked on getting a file
onto Meatloaf (an SD card). May end up documented as a Meatloaf limit.

### 7. A second target: EasyFlash, alongside One ROM

Wanted for the C64 Ultimate and for a C64 with an Ultimate II+ — and as a bonus
it runs on Kung Fu Flash and on real EasyFlash hardware, because EF is a
*format* those devices emulate rather than a competing product.

**Why not the obvious routes.** An REU is RAM behind a DMA controller; it cannot
appear in a ROM window, so it cannot be Tardis. And a custom KERNAL on the
Ultimate is a configuration-menu setting applied at boot, with no UCI command to
change it (the control target has 17 commands — freeze, reboot, REU load/save,
drive power, palette — and nothing for ROM selection). That makes it a one-way
door: `run` could never reach the stock ROMs it needs. EasyFlash inverts the
problem, because the expansion port was designed to let *software* control
banking.

**The mapping is nearly one-to-one with what we already have** (all figures from
skoe's Programmer's Reference):

| today (One ROM) | EasyFlash |
|---|---|
| KERNAL half `$E000`, always mapped | **ROML `$8000-$9FFF`** — the SAME image in every bank (see below) |
| banks served at `$A000` | **ROMH `$A000-$BFFF`**, `$DE00` selects the bank |
| `SWITCH_SLOT` over RBCP, ~588 us, hardware-only | a **register write**, three cycles, and VICE emulates it |
| 10 flash sets | **64 banks of 16 KB** (1 MB) |
| `run`/`basic`: flash swap + CBM80 + reset | `$DE02` = `MXG 100`, "cartridge ROM off" — a plain C64, ROMs intact, RAM untouched, no reset |
| `EXIT` / RUN-STOP-RESTORE | `$DE02` = `MXG 111` back to 16K |
| `bank_call` lives in the static half so it survives the switch | the **256 bytes of RAM at `$DF00`**, which the spec says is "always visible" and stays available with the ROM off |

Confirmed before planning: `$DE00` works "no matter which memory configuration is
set" (§2.4); `MXG=100` is documented as "Cartridge ROM off (RAM at $DF00 still
available)"; and VICE's `easyflash.c` registers the I/O1 handler at attach with no
mode check, so `$DE02` keeps responding with the ROM off. The hardware reason is
that the ROM windows follow `/GAME` and `/EXROM` while the I/O windows are decoded
from the separate `I/O1`/`I/O2` lines.

#### What is shared, and what is not

Shared unchanged: `shell.c`, `parser.c`, every command, every **bank** (same
`"bnk"` ABI at `$A000`), the editors, `dir.c`, the Epyx code.

The platform-specific set is small and already has a natural seam — **the SVC
table is the HAL**. Banks reach the outside world only through it and the KERNAL
entry points; point those entries at different implementations and the bank source
does not change. Per target:

* **`bank_call`** — `SWITCH_SLOT` vs a `$DE00` write.
* **leave / return to stock** — RBCP swap vs `$DE02`.
* **IEC** — ours (`iec.o`, 902 bytes) vs thin SVC wrappers over the stock
  KERNAL's `$FFB1`/`$FFA8`/`$FFA5`. EF gets those 902 bytes back for free, which
  matters: ROML is 8 KB, the same budget as the KERNAL half.
* **reset / boot** — our reset vector vs EF's Ultimax start-up (the cart supplies
  `$E000-$FFFF` at reset, so **it still boots straight into the shell**; the
  start-up code then switches to 16K mode).
* **settings** — One ROM NV flash vs a file on disk (simplest, works everywhere)
  or EF flash via EasyAPI.
* **`font`** — One ROM only; EF cannot serve a character ROM. Document, do not
  emulate.

**Decided (phase 2): screen and keyboard stay ours.** On EF the
stock KERNAL is present, so `readline` would work over stock `$FFD2`/`$FFE4` — but
the shell would then look and behave like stock (PETSCII case, no `pet2scr`, none
of the C= graphics or colour-code work). The alternative is to keep `screen.s` and
`irq.s` in ROML and hook the RAM vectors (`$0314`, `$0326`, `$032A`), which costs
~1.2 KB of ROML and keeps Tardis recognisably Tardis. That is what phase 2
built: `screen.s` and `irq.s` are in ROML, hooked on `$0314`/`$0326`/`$032A`, and
because the stock `$FFD2`/`$FFE4` are themselves `jmp ($0326)`/`jmp ($032A)`, a
bank calling `$FFD2` reaches our chrout without knowing anything changed.

#### What phase 1 found (the spike is built and green)

`make ef-spike` builds it, `test_ef_spike.py` runs it on a stock machine with the
cart attached, and all four steps pass in VICE: boot from Ultimax, bank via
`$DE00`, kill to stock BASIC via `$DE02`, and return from BASIC. Three findings
change the plan above, and none were predictable from the docs alone:

* **`$DE00` banks BOTH windows at once** — the spec's "the bank is valid for both
  chips, ROML and ROMH". A static half at `$8000` with switched banks at `$A000`
  therefore does NOT work as first written: selecting a bank switches the running
  code away with it, which is exactly how the spike crashed. **The fix is to put
  the same ROML image in every bank**, so only `$A000` appears to change. At 8 KB
  per bank out of 1 MB that is free.
* **The mode switch cannot run from the window it is switching.** The start-up
  code lives at `$E000` in Ultimax and vanishes the instant `$DE02` selects 16K,
  so it copies a three-instruction stub to RAM and jumps there. Same shape as
  `bank_call` living in the One ROM build's static half — and the reason the
  `$DF00` RAM exists.
* **VICE's `-easyflashjumper` is the inverse of what the spec's wording suggests**:
  the jumper *disabled* is the setting that boots the cartridge.

A fourth, smaller one confirms the screen decision: the spike prints lowercase
ASCII through the stock CHROUT and it comes out as uppercase PETSCII. Under a
stock KERNAL the shell would not look like Tardis, which is why `screen.s` and
`irq.s` are to be kept and hooked on the RAM vectors.

**Still to confirm on hardware**: that KFF/Ultimate implement the full register
behaviour, particularly switching the ROM back on with it off. Emulating enough
to run EF game images is a lower bar.

#### Phases

1. ~~**Spike, in VICE**~~ — done. Hardware confirmation still outstanding. A minimal EF cart that boots from Ultimax,
   prints, switches a ROMH bank, kills itself to BASIC, and comes back. Perhaps
   200 lines. It proves the whole mechanism and nothing else in the plan is worth
   starting until it does. Test with `x64sc -cartef`, then on Kung Fu Flash —
   **emulating enough to run EF game images is a lower bar than the full register
   behaviour, so hardware confirmation of the ROM-off round trip is the gate.**
2. ~~**Build split.**~~ — done (`make ef` -> `build/ef/tardis.crt`). One source
   tree, `cfg/ef_rom.cfg` (ROML `$8000` static, ROMH `$A000` banked),
   `src/ef/platform.s` for everything that differs, `tools/make_ef_crt.py` to
   pack the CRT, `test_ef_boot.py` to run it. **It boots to the Tardis prompt on
   a stock machine with the cart attached**, draws the same banner (version,
   brand, free ROM bytes -- `tools/patch_freemem.py` learned the EF layout), and
   runs resident commands. Sizes: ROML 3723/8192 used, ROMH0 5670/8192.

   Three things had to be right, and each failed silently first:

   * **Every bank carries the same ROML.** Phase 1 already found that `$DE00`
     banks both windows; what it did not make obvious is that `bank_call` itself
     runs from ROML and writes `$DE00` halfway through. Boot-time
     `identify_boot_device()` asked for a bank the CRT did not have, ROML read
     `$FF`, and the CPU executed garbage. The Makefile now packs the same ROML
     into banks 0..5, and `test_ef_boot` asserts the invariant on the CRT itself.
   * **A `$0314` hook is not a reset-vector handler.** `irq.s` pushed A/X/Y and
     left through `RTI` -- correct when it owns `$FFFE`, fatal here, because the
     stock `$FF48` has *already* pushed them and expects the handler to exit via
     `$EA81`. The `RTI` popped the stock handler's registers as a return address
     and landed the CPU on a JAM opcode at `$FF09`. The tick body is now a shared
     subroutine (`irq_tick`) with a thin shim per entry shape.
   * **No self-modifying code in ROML.** The bank-entry `JSR` and the banner's
     string pointer both started out self-modified; in flash the store lands in
     the RAM underneath and the fetch still comes from ROM. The `JSR` is planted
     in the `$DF00` cartridge RAM, the string pointer goes through `$FB`.

   Banks 1..5 are `$FF` filler for now, which `bank_call`'s `"bnk"` magic check
   rejects cleanly -- `help` reports *bank unavailable (5)* and the shell
   survives, which is itself a test.
3. ~~**Port the static half.**~~ — done. Boot/start-up, `bank_call` as a `$DE00`
   write with its trampoline in the `$DF00` RAM, the screen/keyboard hooks, and
   **all five banks** (`disk`, `util`, `files`, `edit`, `hex`) served from EF
   banks 1-5. Every shell command now works on this target.

   The SVC table was to go "over stock-KERNAL IEC"; it does not, and the
   alternative is better. `$FFxx` belongs to the stock KERNAL here, so the SVC
   table and the KERNAL entry points are pinned at the **top of ROML, at the
   same offsets with `$Fxxx` -> `$9xxx`** -- `$FF80` becomes `$9F80`, `$FFBA`
   becomes `$9FBA`, and so on. The banks call *ours* either way, so every code
   path stays identical to the One ROM build, quirks included (the synthesized
   EOI byte for drives that go idle instead of sending one; CHROUT's one-byte
   deferral so CLRCHN can send the last byte with EOI). Mixing our IEC with the
   stock KERNAL's would have meant two bus drivers sharing one set of lines.

   The bank images are the One ROM ones **relinked, not rewritten**: same C,
   same shared asm, only `crt0_*.s` reassembled with `-D EF_BANK=1`, which picks
   the relocated RAM window (`src/bank_cstack.inc`) and the `$9Fxx` entry points
   (`src/kernal_shims.inc`). The linker configs are *generated* from the One ROM
   ones by `tools/make_ef_bank_cfg.py` -- the difference is two mechanical
   rewrites, and five hand-maintained near-duplicates would have drifted.

   Two things bit, both silent:

   * **The bank RAM window was write-only.** Banks keep DATA/BSS/C-stack at
     `$9D00-$9FFF`, which is plain RAM under the One ROM's `$A000` window but
     **inside ROML** here -- the write lands in the RAM underneath, the read
     comes back from flash. Every C bank entry ran its init and then did
     nothing: `border 3` left `$D020` alone, with no error. `about` hid it
     completely, being assembly that skips `bank_init`. The window is
     `$C800-$CDFF` now.
   * **`bank_call` computed `entry*6`**, not `entry*3` -- two `asl`s is x4, not
     x2 -- so `about` (entry 1) ran `debug` (entry 2).

   **This target tests things the One ROM build cannot.** There, a served bank
   is inert in VICE: `bank_call` falls back to running the image out of the RAM
   under `$A000`, so the suite exercises a stand-in and the real serving path is
   hardware-only. Here the banking is emulated, so `test_ef_banks.py` runs the
   actual mechanism -- including `help`, whose failure mode (following the
   dispatch table's name pointers into the bank's own code) cannot be reproduced
   in VICE on the other target at all.

   A follow-up from the first live session: `ef_cold` has to re-apply the
   screen setup after CINT. CINT leaves stock blue *and* `$D018 = $15`, the
   uppercase/graphics charset -- and Tardis runs the lowercase one, which is
   what makes its encoding ASCII-consistent, so the shell came up in the wrong
   font with every lowercase letter drawn as a graphic.

   Known gap: `fload` reports *fast load not supported* against VICE's 1541.
   That is the documented Meatloaf-only limitation of our Epyx install payload,
   not an EF regression -- a real 1541 needs genuine Epyx drive bytes.
4. ~~**Port the handover.**~~ — done. `run`/`basic` are `$DE02` writes, and it
   did delete work: no CBM80, no reset, no `RESTOR` fragility, no stock-KERNAL
   patching. `basic` gives a genuine stock C64 reporting **38911 bytes free**,
   `basic print 1+1` prints `2`, and a loaded BASIC program survives into stock
   BASIC and LISTs.

   * **The CBM80 plant moved out of `fs.c` into the platform layer.** It is a
     One ROM handover detail -- that build only reaches the run stub through the
     stock reset's cartridge-autostart path -- and doing it in shared code cost a
     program loaded at `$8000` its first nine bytes on a target with no use for
     the structure. `launch_stock_program` calls `rbcp_launch_stub()` now; One
     ROM plants and swaps, EasyFlash turns the cart off and jumps to `$CF00`.
   * **Order matters on the way out.** The cartridge has to be off *before* the
     stub runs, because the stub calls RAMTAS, whose non-destructive walk goes
     up to `$A000`. With ROML still mapped the readback comes from flash,
     RAMTAS decides RAM ends at `$8000`, and BASIC comes up 8K short. `MEMSIZ ==
     $A000` is asserted for exactly that reason.
   * **The escape hatch had to move into the cartridge's `$DF00` RAM.** The stub
     writes its address into `$0318` (RUN/STOP+RESTORE) and `$0302` (a program
     exiting to READY) -- and then the cartridge goes away, so a ROML address
     would be RAM holding the loaded program by the time either vector fired.
     `$DF00` stays visible with the ROM off, which is what it is there for. It
     is armed by both launch paths before the switch, since afterwards there is
     no code of ours mapped to arm it.

   **The escape round trip is now tested, which it never was anywhere.** On the
   One ROM build the whole handover is inert in VICE, so `run`/`basic` and the
   way back were hardware-only; here the only moving part is `$DE02`, and
   `test_ef_run.py` takes the armed stub and watches Tardis come back.

   **Not ported: a typed `EXIT` at the stock BASIC prompt.** On One ROM that is
   an IGONE wedge patched into the stock KERNAL's tape space, and there is no
   ROM to patch here -- the stock KERNAL is real silicon. The escape itself is
   already a register write and RUN/STOP+RESTORE works; making `EXIT` work would
   need a RAM `$0308` wedge, which is the design rejected in v0.1.84 because
   BASIC's own init overwrites it. It is achievable -- our stub controls the
   init, so it could hook `$0308` after `$E453` -- but bare `basic` currently
   cold-resets and never runs our code again, so it would first have to route
   every exit through the stub. A separate piece of work, not a register write.
5. **Settings, then release.** Both artifacts from one tree.

#### Why this is worth doing beyond the hardware support

**The EF build would be the first fully testable one.** Today the swap, served
banks, NV and the stock-KERNAL patch are all inert in VICE and cost real days to
debug on hardware. `x64sc` emulates EasyFlash banking and the registers, so on
that target the bank mechanism, the shell and the disk commands are all
exercisable end to end — against the real path, not a harness-seeded stand-in.

### 8. Fast loading on a REAL 1541 -- WORKS, and matches the Epyx cart in VICE (v0.2.49)

`src/drive1541.s` gives a drive that genuinely runs 6502 -- a stock 1541, a
Pi1541 -- real drive-side code instead of the 75 bytes of `$EA` a Meatloaf
merely fingerprints. Byte-perfect over 16KB / 65 sectors, repeatedly.

**Measured (VICE cycle counter, PAL):**

| | time | rate |
|---|---|---|
| standard IEC (`load`) | 49.0 s | 334 B/s |
| Epyx fast (`fload`) | 22.3 s | 736 B/s |

That is **2.2x**, against the 5-5.5x a real Epyx cartridge gets. The gap is
understood, and measured rather than guessed. Note the baseline is OUR
standard-IEC `load`, not the stock KERNAL's -- a stock KERNAL LOAD is a little
quicker than ours, so against that the ratio would be lower still.

Where the time goes on a 16KB load:

* **install 2.1 s** (the 566-byte drive routine over 18 separate `M-W`
  command-channel transactions) and **directory search 2.1 s**. One-off, so
  they barely move the 16KB figure but they dominate a small load -- and they
  are the reason a 200-byte `fload` takes ~7 s.
* **transfer 22.3 s**, which splits:
  * **~30% rotational latency** -- 103 ms per sector, about half a revolution.
    We read a sector, transmit it (~236 ms), and only then ask for the next, by
    which time the disk has turned past it. A real Epyx overlaps the two.
  * **~70% per-byte protocol and turnaround** -- about 940 C64 cycles a byte
    where the wire itself needs ~60. Only ~70 of those are either side's wait
    loop (measured), so it is genuine code on both ends: ~180 cycles of host
    path (sample, descramble, store, loop) and ~190 of drive path (hold, CLK
    low, build the next byte's four pair values, handshake).

**An attempt at Epyx speed, and where the time actually goes.** Three
structural changes were tried and all three failed, which is what finally
pointed at the real bottleneck.

1. **Dropping the per-byte CLK handshake** (it serialises the drive's whole
   turnaround with the host's -- the host cannot release DATA until the drive
   says it is ready). Catastrophic: 592 s and 16320 of 16384 bytes corrupted.
2. **Adopting the reference block structure** -- CLK high for the WHOLE block,
   per-byte DATA handshake only, CLK dropped at the block's end, exactly as
   `transmitEpyxBlock` does. Also catastrophic (451 s, everything corrupted).
   It works for Meatloaf because an ESP32 preps the next byte in ~0 time; our
   drive needs ~90 cycles after the release, so the host gets back to its own
   release first and the drive is never in its poll in time. **The reference
   design needs the drive to be reliably faster than the host, and ours is
   not.**
3. **Blanking the screen** (what the real Epyx cartridge does, removing
   badlines entirely). No effect -- 0.3%.

Masking the C64's 60 Hz keyboard IRQ likewise changes nothing (0.4%).

**The bottleneck is rotational latency, not the protocol.** A PC histogram
taken during the transfer (sampled via the monitor, so only ~25 usable points
-- the harness's `run_for` sleeps WALL-CLOCK while VICE runs in warp, so each
sample covers ~1.5 s of emulated time) puts roughly **70% of the transfer in
`wait_clk_hi`** -- the host waiting for the drive to deliver the next block --
and only ~25-30% in the receiver. The arithmetic agrees: 16KB is **65
sectors** in **20.7 s = 319 ms per sector**, and a 1541 turns at 300 rpm, so
that is **1.6 disk revolutions per sector**. We are losing most of a
revolution on every one.

**Why we lose it:** the DOS lays a file out with an interleave chosen so the
next chained sector arrives under the head just after the drive has finished
with the current one -- roughly **110 ms** later. Transmitting a block costs
about **71 ms** (254 bytes at ~280 cycles) plus the per-block job setup and
handshake. We come in over the interleave window, miss the sector, and pay a
**full extra revolution (200 ms)** to get it back.

**That reframes the whole problem, and it is good news**: catching the
interleave instead of missing it would put 16KB at about **7.2 s = 6.3x
stock**, which is the Epyx figure. It also means per-byte savings matter far
more than their size suggests -- they do not buy a few percent, they decide
whether each sector costs 110 ms or 310 ms. **Expect a cliff, not a gradient.**

**The turnaround was then trimmed, and it changed NOTHING.** The cliff model
above predicted that shaving per-byte cycles would tip each sector from ~310 ms
to ~110 ms. About 50 cycles a byte came off: the drive stopped rebuilding
`v_base` from a VIA2 read on every byte and round-tripping through `v_byte`
(18), the block's byte index moved from `v_off` into Y (8), the ATN check went
from per-byte to per-block (6), and on the host the display was blanked for the
transfer so the receiver could skip its badline pacing entirely (~16, plus the
VIC no longer stealing cycles on every eighth line). On a 254-byte block that
is ~12.7 ms.

**Per-sector cost was 296.8 ms before and 296.8 ms after** -- identical to the
tenth of a millisecond, with the transfer still byte-perfect. Not a cliff, and
not even the linear saving. **The per-byte protocol cost is therefore not on
the critical path at all**, and no amount of shaving it will help: a sector
costs ~1.48 disk revolutions whenever we ask for it. The interleave-window
story was the right shape but the wrong premise -- we are not marginally over a
threshold, the drive's fetch simply dominates.

Kept from that experiment: the drive-side trimming (14 bytes smaller, same
speed, still zero bad bytes). **Reverted: the screen blanking and the badline
skip** -- a visible behaviour change during every load, bought nothing.

**Two measurement lessons, both of which had been corrupting numbers here.**
The harness's `run_for()` **sleeps WALL-CLOCK while VICE runs in warp**, so a
completion poll overshoots by ~1.5 s and no amount of averaging fixes it; pass
`+warp` to turn warp off and the same test times to the hundredth of a second.
(A "20.73 s" reading earlier in this work was that noise; the true figure has
always been ~22.7 s.) And per-sector cost is far better isolated by the
**slope** between a 1-sector and a 17-sector file than by dividing a total,
because it subtracts the fixed overhead instead of smearing it.

**That fixed overhead is 3.3 seconds** -- the drive install (566 bytes over 18
`M-W` transactions) plus the directory search -- and it is now the most
actionable number here. It is invisible against 16KB but it is the ENTIRE cost
of a small load: `fload small` (one sector) takes 3.6 s, of which 3.3 s is
setup. Caching the installed loader across calls, or shrinking the upload,
would matter far more to everyday use than the transfer rate does.

**MEASURED, end to end.** Four independent measurements now agree, and they
replace every estimate above them:

| quantity | how | value |
|---|---|---|
| interleave window | read the chain out of the .d64 | 10 of 21 sectors = **95.2 ms** |
| transmit, disk out of the loop | ship the same buffer 20 vs 40 times, take the slope | **68.8 ms** a sector |
| disk wait | drive PC profile (sync search + our job poll) | **~175 ms** a sector |
| total | cycle counter | ~299 ms a sector |

**The transmission FITS the window** -- 68.8 ms against 95.2, with 26.4 ms to
spare -- and we miss anyway, waiting ~175 ms where catching would cost ~95. So
the overshoot is neither the wire nor the rotation: it is **the DOS's own
per-job overhead**, the ~15% of drive time in `$D5A6`, `$EA0E`, `$EC14`,
`$F53D` and friends that is neither the sync search nor our code. That is more
than the 26.4 ms of slack we have, so every sector arrives a little too late
and costs most of a turn.

**How to measure this, because it took several wrong turns.** The drive's own
RAM is readable from VICE's monitor with the `8:` memspace (`m 8:051e 0520`), and
the drive CPU's registers by `device 8:` then `r` -- which is how the profile
above was taken. **Bound the sampling to the load**: while the memspace is the
drive you cannot read the C64's screen, so a fixed-count loop keeps sampling
long after the transfer ends and fills the histogram with the idle DOS
(`$EC12-$EC2D`, a channel scan). That contaminated the first profile completely
-- 80% idle loop -- and inverted the conclusion. Switch back to `c:` every 25
samples and test the screen.

**The DOS job's overhead is now measured directly, and it is the whole
problem.** Read track 17 at sectors 0, K, 2K ... with 1 byte shipped per sector
(so transmission is ~free) and find the smallest K that still catches. Slopes
over 20 extra sectors:

| K | gap | measured | |
|---|-----|----------|---|
| 2 | 19.0 ms | 219.5 ms | miss |
| 6 | 57.1 ms | 254.4 ms | miss |
| 8 | 76.2 ms | **75.9 ms** | **catch** |
| 10 | 95.2 ms | **98.8 ms** | **catch** |

So the job needs **57-76 ms of headroom with nothing being transmitted at all**.
That is the time from the sector's header passing under the head to the job
reporting complete: the read itself is ~9.5 ms and the GCR decode a few more, so
**40-60 ms of it is DOS bookkeeping**. Against a 95.2 ms window that leaves ~25
ms for transmission, and we need 68.8 -- which is exactly why we miss every
sector, and why trimming the wire never moved the total.

**The budget, therefore:** get post-header work under **26.4 ms** and 254 bytes
fit the window. ~20 ms is plausible for a lean reader (read + decode, no
bookkeeping), leaving ~6 ms of margin -- tight, so the wire trimming that was
worthless before becomes worth keeping afterwards.

**A trap in measuring this:** `sed`-ing an operand like `adc #K` by pattern hits
every other `adc #` in the file. The first run of this sweep did exactly that,
corrupted three instructions, and reported that all K values "caught" with the
reads taking no time at all. Patch through a unique marker instead.

**And the job queue is NOT the fat -- the read job is already lean.**
Disassembled from the drive ROM in VICE:

```
$F4D1  JSR $F50A     ; find the header ($F510), then wait for the data sync ($F556)
$F4D4  read 256 GCR bytes -> ($30),Y
$F4DF  read 70 more  -> $0100,Y
$F4ED  JSR $F8E0     ; GCR decode
$F4F0  checksum check
```

Five steps, nothing removable. The 57-76 ms is **read (~9.5 ms) + GCR decode +
verify**, and the decoder at `$F7E6`/`$F8E0` is byte-at-a-time bit shuffling --
tens of milliseconds for 256 bytes on a 1 MHz 6502. **Epyx calls this same stock
ROM decode** (it is why a plain .d64 works for it), so it pays the same cost. So
forcing the queue with `$B0`/`$E0` would save the dispatch and nothing that
matters: **the drive-side rewrite is not the win, and this supersedes the
previous section's conclusion.**

**What is left is the wire, and now the budget is exact.** The job needs 57-76 ms
of the 95.2 ms window, so transmission has to fit in the remaining **19-38 ms**.
We take **68.8 ms**. That is the whole gap: the wire must get roughly **2-3x
faster**, from 271 us a byte to about 100-150.

Which is consistent with the one figure we have for the real cartridge: at 2500
bytes/s overall it moves a 254-byte sector every 101.6 ms = 0.51 turns, meaning
its transmission fits the same window ours overruns. Epyx is not doing anything
clever with the disk -- it reads a sector, decodes it with the ROM routine and
ships it, exactly as we do. **It just gets the bytes out fast enough.**

**THE REAL CARTRIDGE, MEASURED.** Epyx FastLoad v3 was run in VICE against the
same `bench.d64`, stock ROMs, `LOAD"BENCH",8,1`:

| | time | rate | vs stock | ms/sector | turns |
|---|------|------|----------|-----------|-------|
| **Epyx v3** | **9.50 s** | 1725 B/s | **4.77x** | 146.1 | 0.73 |
| ours | 22.68 s | 722 B/s | 2.00x | 348.9 | 1.74 |

Profiling the DRIVE during Epyx's own load splits that 146 ms:

| where | Epyx | ours |
|-------|------|------|
| DOS sync search | 35.1 ms | } |
| DOS GCR decode | 21.4 ms | } ~70 ms -- the same ROM doing the same work |
| DOS header search | 7.8 ms | } |
| **its own drive code (the wire)** | **31.2 ms** | **68.8 ms** |

**The disk side is identical and the wire is 2.2x slower.** That settles every
open question in this section: the fetch is not the problem, the job queue is
not the problem, GCR is not the problem. **254 bytes have to leave the drive in
~31 ms instead of 68.8** -- about **123 us a byte against our 271**.

**Where our 271 us goes:** the four pairs are only ~67 cycles of it. The rest is
per-byte handshake turnaround -- announce ready, wait for the host's release,
hold, release, wait for "got it" -- plus `prep_byte` building the next byte's
four pairs inside that path. Epyx's wire is the same 2-bit protocol at the same
spacing, so the difference is not the encoding: it is what each side does
BETWEEN bytes.

**Step 1 done: nibble tables for the pair build.** Pairs are a pure function of
a nibble, so two 16-entry tables (`t1[n] = (n & $0A) | base`, `t2[n] =
((n<<1) & $0A) | base`, built once a block) replace the whole shift/mask/ora
chain in `prep_byte`. Measured on the no-disk slope: **68.8 -> 65.5 ms a
block**, 271 -> 258 us a byte. Correct, but only ~5% of the ~55% needed.

**And the remaining 2x needs a different per-byte STRUCTURE, not more trimming.**
At 31 ms a sector the budget is 122 cycles a byte; the four pairs alone are 67,
leaving ~55 for BOTH turnarounds. The drive would have to go from releasing the
wire to being ready with the next byte's pairs in ~25 cycles, and per-byte pair
computation cannot do that however it is written.

**The specific obstacle, worth writing down because every variant hits it:**
pair 1 must reach `$1800` at read+8, so it has to be in a REGISTER when the poll
fires -- `lda t1,x` there lands it at read+12. That forces a store-to-variable in
prep. Fetching the later pairs from the tables inside the 13-cycle gaps then
needs `ldx v_lo` + `lda t,x` + `sta` = 12 cycles where 13 are available but the
load must END the gap, leaving 9 for a 4-cycle `ldx` plus a 4-cycle `lda` -- one
cycle short, every time. Zero-page copies of the pair variables would close it
(3-cycle loads), but the drive's ZP belongs to the DOS and `$50-$5F` is not free.

**Step 2 done: the send loop is the cartridge's shape now.** Profiling the real
Epyx drive code (sample the drive PC during ITS load, then disassemble the hot
RAM addresses) showed a per-byte loop of ~62 cycles against our ~125, and four
reasons for it, each of which was a deliberate cost of ours:

* **ONE wait a byte** -- `bit $1800 / bne` = 7 cycles -- where we had a CLK
  announce, a `@holding` re-check and a separate `@got`.
* **Ten-cycle pair spacing, not thirteen.** Our 13 existed to give a 9-cycle poll
  three cycles of margin; a 7-cycle poll gets the same margin at 10.
* **No `ora v_base`.** We spent four cycles a pair preserving ATNA and the
  device-address bits; bits 5-6 are inputs and ATNA is not wanted mid-transfer,
  so the cartridge just writes the bare nibble.
* **`and #$0F`, not `#$0A`** -- bits 2 and 0 are the INPUT lines, so writing them
  is harmless, and `$0F` is what the shifts already leave behind.

Adopted wholesale: `prep_byte`, `xmit_pairs`, `wait_got`, `build_tables` and the
`t1`/`t2`/`v_p1..4` state are all gone, the blob is **580 -> 455 bytes**, and the
transfer is still byte-perfect. **Ten-cycle spacing IS the Meatloaf timing**, so
`RECV_PAD` is 0 on both paths and the host needs no special case at all.

**But the wire only went 65.5 -> 63.0 ms a block, because the limiter moved.**
Of 248 us a byte, the four pairs and the drive's whole loop are ~62 cycles;
**~204 are the host**. That is now the entire remaining gap, and the drive side
is done -- it matches the cartridge.

**Step 3: the host receiver, and a correction about the cartridge.** From
notes on the actual `.crt` (`~/Downloads/epyx-fastload-cart-notes.md`): **the
cartridge never writes `$D011` -- the display stays on.** An exhaustive scan of
its stores into `$D000-$D3FF` finds only `$D015` (sprites) and `$D01A` (VIC IRQ
mask), saved, cleared and restored. It gates badlines with a **256-byte table at
`$8300` indexed by `$D012`**, biased by `7 EOR YSCROLL`, and the live entry
doubles as the AND mask that releases the lines. "Cost of keeping the screen on:
nothing." An earlier draft of this section said it blanked, and a blanking
change was briefly made here on that basis; both were wrong.

What landed instead:

* **The badline gate is a table lookup** (`badtab`, bank build only), ~10 cycles
  against the raster arithmetic's ~18, with the entry used as the DATA mask so
  the release costs an `and` rather than an `and #imm`. Screen stays on.
  We block offsets 1..3 where the cartridge blocks two, and that is not
  over-caution: its byte is ~63 cycles, about one raster line, so it needs only
  the line it starts on; ours spans two to three.
* **The dead per-byte CLK wait is gone** -- the drive answers in ~29 cycles now,
  so it is always waiting on us.
* **`next_byte` is bypassed on the common path** (~11 cycles); the framing only
  matters at a block boundary. Guarded to the bank build, since KLOAD has no
  room -- it must fit the 684-byte tape region and overflowed when this was
  unconditional.
* **Sprites are saved, cleared and restored** across a transfer. They steal VIC
  cycles exactly as badlines do; the shell never enables one, but a program
  loaded before a second `fload` can leave `$D015` set.

**22.68 -> 20.93 s, 2.00x -> 2.17x**, still byte-perfect, screen still on.

**The cartridge's own per-byte budget, from the notes' section 7** (and it
corrects the "one byte per raster line" figure -- a byte is ~1.7 lines):

| stage | cycles |
|-------|--------|
| `JSR $8425` + raster gate (`LDY $D012` / `LDA ($94),Y` / `BEQ`) | 17 |
| release lines, `ORA #$20 / TAY`, 4x `NOP` | 20 |
| 4 samples, `LDA $DD00` + 3x (`LSR/LSR/NOP/EOR $DD00`) | 34 |
| re-assert, `EOR $A3 / TAY / LDA $8458,Y`, `RTS` | 19 |
| caller: `STA ($AE),Y`, `INC $AE` (+`INC $AF`), `DEX`, `BNE` | ~19 |
| **total** | **~109** |

So the target is **109 cycles a byte, not 63**, and we were at 161 -- a 1.5x gap,
not the 2.5x assumed above. It also answers the three questions worth asking of
any such comparison: it **does** re-assert DATA every byte, its descramble
lookup is **after** the sample window, and it **does** pay a per-byte
`JSR`/`RTS`. Its structure is ours. The difference was almost entirely in the
CALLER: theirs is four instructions and a `DEX`, ours carried `BLK` in memory
AND a 16-bit `TOTL`/`TOTH` running total beside `DST`.

**Dropped the running total (bank build only): ~10 cycles a byte.** `DST`
advances with every stored byte, so the total is `DST - LADR`, and both readers
of it -- the <3-byte check at EOF and the progress dots -- are per BLOCK and can
subtract there. KLOAD keeps the counter: deriving it costs three bytes it does
not have in the 684-byte tape region.

**Also taken: the cartridge's re-assert trick.** Its stage 2 computes the
ASSERTED line value once (`ORA #$20 / TAY`) inside padding it is burning anyway,
so stage 4's re-assert is a single `STY $DD00`. Ours was a read-modify-write
every byte (`lda`/`ora`/`sta`), and it also forced the folded value to be
stashed in X and pulled back with `txa` afterwards, since the `lda` clobbered A.
Both are gone: the padding does `ora #B_DATA / tay`, the re-assert is `sty`, and
the fold stays in A. **~10 cycles a byte, and the sample offsets are untouched**
-- the padding is ten cycles either way. KLOAD keeps the old sequence.

**Where the wire stands: 68.8 -> 42.0 ms a block**, measured on the no-disk
slope, with the screen ON throughout. (A blanked build measured 41.0, so the
badline table gives back nearly everything blanking did, legitimately.) The
cartridge's transmit is ~33 ms, so we are ~27% off rather than the 2x we
started from.

**20.93 -> 20.05 s, 2.26x stock, byte-perfect.**

**SIDE BY SIDE WITH THE REAL CARTRIDGE**, both profiled the same way (sample
the drive's PC during its own load):

| per sector | Epyx (146.1 ms) | ours (274 ms) |
|---|---|---|
| job-wait spin, own code | *(within its 31.2)* | **80.3** |
| DOS sync search | 35.1 | **76.7** |
| DOS GCR decode | 21.4 | 16.4 |
| DOS read GCR bytes | 3.9 | 5.5 |
| transmit + host-wait | ~31 | ~42 |
| **disk phase** | **~95 ms = 0.48 turns** | **~179 ms = 0.90 turns** |

Our code is not slower -- the decode even comes in under theirs. The disk phase
is nearly a whole extra revolution, which is the miss itself, not slow work.

**And the accounting says we should NOT be missing.** From sector N's header to
issuing the job for N+1: read 5.5 + decode 16.4 + transmit 42 = **63.9 ms**
against a 95.2 ms gap, i.e. 31 ms of slack. So one of those inputs had to be
wrong, and the way to find out is to measure that span directly rather than
assemble it: read track 17 at sectors K apart **with the real 254-byte payload**
and find the smallest K that still catches.

| K | gap | measured | |
|---|-----|----------|---|
| 8 | 76.2 ms | 277.4 ms | miss |
| 12 | 114.2 ms | 170.6 ms | miss |
| **16** | **152.3 ms** | **151.7 ms** | **catch** |
| 20 | 190.4 ms | 197.6 ms | catch |

**The true span is 114-152 ms, not 63.9.** More than double the sum of its
parts, against a 95.2 ms window -- which is the whole reason we miss every
sector, and why per-byte trimming kept not moving the total. Roughly 50-90 ms
is unaccounted for by read + decode + transmit.

**MEASURE ON THE LINEAR METRIC, NOT END TO END.** This deserves to be a rule,
because getting it wrong wasted several changes here. Everything below the
interleave threshold is invisible in the total: a change worth 4 ms a block
moves a 20 s load by nothing at all, because the sectors that missed still miss.
So a "revert anything that does not show" policy **guarantees you never cross
the threshold**, since crossing it requires accumulating exactly those
individually-invisible gains. Judge each change on the **no-disk slope** (ship
the same buffer 20 vs 40 times, take the difference) which has no cliff in it,
and keep anything correct that improves it.

Two changes were nearly discarded that way and are kept:

* **The badline gate blocks TWO offsets, not three.** What has to be clear is the
  TIMED window -- gate to last sample, ~62 cycles -- not the whole ~127-cycle
  byte, whose untimed ends can take DMA without harm. So the start line must be
  neither the badline nor the one before it: `YSCROLL-1` and `YSCROLL`. That is
  what the cartridge blocks, for the same reason.
* **CIA1's timer IRQ is masked for the transfer** (`$7F -> $DC0D`, restored to
  `$81`), as the cartridge does. Our receiver masks interrupts per BYTE with
  `php`/`sei`/`plp`, so between bytes they are back on and the 60 Hz keyboard
  IRQ lands inside a block.

Together: **42.0 -> 40.9 ms a block**, and 16KB byte-perfect over three runs.
Cumulative for the session: **68.8 -> 40.9**, against the cartridge's ~31.

**The SEI hypothesis is DEAD.** The idea was that holding interrupts off for a
whole block (~43 ms) made the drive's controller lose its place, so the penalty
would scale with transmit time. Tested by splitting each sector into TWO blocks
of 127 with a `cli` window between them -- the host needs no change, since it
reads a length byte per block already, so two blocks of 127 look exactly like
one of 254. Result: **20.25 s against 20.05**, i.e. slightly worse for the extra
handshake, and byte-perfect. Giving the controller a mid-sector window buys
nothing.

**What the numbers point at instead: RASTER RESONANCE in the badline gate.**

| | code | measured | gate stall |
|---|------|----------|-----------|
| cartridge | 111 cyc/byte | 31 ms/block = 122 cyc | **11** |
| ours | 127 cyc/byte | 43 ms/block = 169 cyc | **42** |

We stall at the gate nearly four times as much, and the reason is the ratio of
byte length to raster line (63 cycles PAL):

* the cartridge's byte is **111/63 = 1.76 lines**, so the raster offset drifts
  quickly and its stalls are spread thin;
* ours is **127/63 = 2.02 lines**, so the offset advances by almost exactly 2
  every byte. Against an 8-line badline period that walks 0, 2, 4, 6, 0 ... --
  hitting a blocked offset every fourth byte -- and because the drift is only
  0.016 lines a byte it takes ~60 bytes to escape a bad phase. The resonance is
  what makes the stall long, not just frequent.

**31 cycles a byte of stall is ~8 ms a block, which is the ~11 ms the threshold
needs.** And the fix falls out of the same arithmetic: **cutting ~16 cycles both
shortens the byte and moves the ratio to ~1.76**, the cartridge's own figure. The
16 cycles are known and enumerated above -- `php`/`plp` around every byte (7,
which the cartridge does not pay at all: it masks CIA1 once per load) and the
caller's block counter in memory rather than in X (10). The descramble already
indexes through Y, so X is free the moment the badline gate stops using it.

**The restructure is DONE.** Four pieces, bank build only:

* the badline gate indexes through **Y**, freeing X;
* `_epyx_recv_byte` no longer does `php`/`sei`/`plp` -- `_epyx_recv_prg` holds
  SEI for the whole transfer, as the cartridge masks CIA1 once per load;
* the block's byte count lives in **X** across the call, so the inner loop ends
  `dex / bne` (5 cycles) where testing and decrementing a memory `BLK` took 12;
* `block_hdr` is split out of `next_byte` so the boundary work is reached only
  at a boundary. KLOAD keeps the monolithic version -- the split costs a
  `jsr`/`rts` pair and it has **zero** bytes spare in the 684-byte tape region,
  which the build reports as a one-byte overflow.

**The trap, and it is a good one:** `_epyx_recv_byte` ended with `ldx #$00`,
cc65's char-return convention. That wiped the new counter on every byte and the
loop ran for ever. Both C callers (`dir.c`) assign to an `unsigned char`, which
needs only A, so it is guarded out on this build -- and **X being preserved is
now part of the routine's contract**. The failure mode is a hang rather than
corruption, so it surfaces on the first run.

**Wire: 40.9 -> 36.9 ms a block**, 161 -> 145 us a byte, exactly the ~16 cycles
predicted. Byte-perfect, and the code is now ~111 cycles a byte -- the
cartridge's own figure.

**The resonance theory only half held.** At ~111 cycles the byte is 1.76 raster
lines, the same ratio the cartridge has, yet our gate stall only fell from 42 to
34 cycles where the cartridge pays 11. So the ratio is not the whole story and
something else about our gate stalls longer. That is the next thread, and it is
worth ~9 ms a block if it comes out.

**Two of its tricks we have not taken:**

* **The count byte rides in the block's own link field.** `$0591 DEX / STX
  $0401` overwrites the chain link with the byte count, so it goes out as the
  first byte of the block's burst: no separate length transaction and no extra
  handshake. We still send the length as its own byte.
* **The drive reuses the ROM's parser wholesale** -- it fills `$0200` with the
  filename and calls `$C146` (PARSXQ), then copies the buffer the ROM left. That
  is how its resident loader fits in 256 bytes and why the first block costs it
  nothing. Our `find_file` walks the directory itself.

**The host's per-byte fat, in likely order:** the badline pacing (~20 cycles, and
the real cartridge simply BLANKS THE SCREEN so it has none), `php`/`plp` and
`jsr`/`rts` around every byte (~20), `next_byte`'s block accounting, and the
store loop. The sample window itself is 44 cycles (+14/+24/+34/+44) and is not
negotiable. Budget: the host must reach ~80 cycles a byte for 31 ms a block.

**The attack, in order:**
1. **Batch the pair precomputation.** Build a chunk of bytes' pairs up front so
   `prep_byte` leaves the inter-byte path entirely; the drive then holds CLK low
   only once per chunk instead of once per byte.
2. With the drive always ready inside a chunk, **the per-byte CLK handshake can
   go** -- which is what failed before (see above) purely because our drive could
   not prep in time. Batching is the precondition that experiment lacked.
3. Keep the earlier per-byte trimming, which was worthless while we were deep in
   the miss region but is margin once we are near the threshold.

Target 31 ms a sector. At that point the cycle fits where Epyx's fits, and 16KB
should land near 9-10 s.

**Method note:** the drive's `@ready` poll cannot be instrumented in place.
Adding a counter takes the loop from 9 cycles to 15 and the transfer degrades
25-fold -- the loop's length is part of the protocol.

**Also still open:** confirming on real hardware. VICE models the drive CPU and
ROM faithfully but not the analogue end (motor spin-up, head settling); the
loader waits on the job queue for those, so the risk is low but untested.

**THE GAP IS CLOSED (v0.2.49).** Re-measured on a fresh disk (16KB file, 65
sectors at c1541's standard interleave), timed exactly -- a store watchpoint on
the file's last byte stops the emulator and the stopwatch gives the cycles:

| | 16KB | 1 sector |
|---|---|---|
| Epyx v3 cartridge | 9.28 s | 2.07 s |
| fload, v0.2.48 | 21.49 s | 3.25 s |
| **fload, v0.2.49** | **9.00 s** | **1.90 s** |

Guarded by `test/test_fload_speed.py`. Five changes, in the order they paid:

1. **The controller tick (21.5 -> 13.6 s).** The cartridge's drive code, dumped
   from drive RAM mid-load (it lives at `$0500`, sector buffer `$0400`, job 1),
   does one thing ours did not before every read: `ldy #1 / sty $1C05` with the
   latch high put back after. The 1541 runs its job queue from VIA2 T1's IRQ,
   latched at `$3A00` = 14.8 ms, so a job posted between ticks sat unseen for
   up to a whole period; reloading the counter as `$0100` fires the IRQ in
   256 us. **This was the "50-90 ms unaccounted for" above** -- not DOS
   bookkeeping. The K-sweeps measured post-to-catch latency and the tick was
   inside it.
2. **The badline gate (13.6 -> 10.3 s).** Tracing the drive with breakpoints on
   job-post and job-done showed the cause directly: we sent a sector in 37 ms
   against the cartridge's 31.5, and the disk wait alternated 57 / 250 ms --
   catch, miss, catch, miss. Hops that wrap past the end of the track get the
   tail gap and a few ms extra; the others do not, and at 37 ms we missed every
   one of those. The 6 ms was the gate: `badtab` blocked offsets 1..3 and only
   YSCROLL-1..YSCROLL can reach the badline's DMA from the timed window (~58
   cycles from the `$D012` read to the last sample). Narrowed, transmit is
   31.3 ms, the cartridge's figure, and every sector catches. The "resonance"
   theory above was chasing this.
3. **No `I0` (setup).** On job error `$0B` the loader copies the header's ID
   (`$16/$17`) into the controller's (`$12/$13`) and retries -- also the
   cartridge's method. The `I0` round trip was 1.36 s, although most of that was
   motor spin-up, which simply moved to the first read (see 5).
4. **A bootstrap (setup).** M-W runs ~2.4 ms a byte, so the 15 M-Ws of the
   loader were 1.5 s. Now `src/drive1541_boot.s` (78 bytes, three M-Ws, M-E
   `$0400`) clocks the loader in over the host->drive Epyx send
   (`epyx_send_byte`, CLK edge per bit, host-paced so badlines are harmless),
   straight into `$0500`, and the filename rides in the loader's header. The
   bulk goes through an asm loop (`epyx_send_mem`); through the C loop it was
   ~0.7 ms a byte.
5. **Spin-up overlapped (setup).** Two tiny M-Ws post a SEEK (`$B0`) to track 18
   into job 0 before the upload, so the controller spins the motor up and
   positions the head while the bootstrap and loader go up. The loader's first
   read uses the same job slot and follows it; a job is taken and executed
   within one controller IRQ, so the overwrite cannot race it.

Two build notes from this. `badtab`'s `.align 256` padded the disk bank by 236
bytes without aligning anything (the segment is not page-aligned); it is gone,
since a page cross costs a cycle before the DATA release, where it is harmless.
And a `git stash`/`pop` inside the same second as a rebuild left a stale
`bk_fastload.s` that make believed current -- several "no change" measurements
were that. `make clean` before believing a null result.

**Still open:** real hardware (VICE models the drive's CPU and ROM, not the
motor or head settling; the loader waits on the DOS's job queue for those, so
the risk is low), and KLOAD -- the stock-side LOAD wedge -- still has only the
Meatloaf path, so programs launched with `run` that LOAD more files get stock
speed on a real 1541. The cartridge speeds those up.

**And KLOAD used to HANG a real 1541 (fixed v0.2.50).** It M-E'd the Meatloaf
fingerprint with no probe -- the bug `fload` had until v0.2.48 -- so every LOAD
after `run`/`basic` (`,8`, `,8,1`, `"$"`) crashed the drive, and the stock
fallback then waited on it for ever. Reproduced in VICE with a hand-patched stock
KERNAL; the unpatched one loads the same file in 2.6 s. Now the swap probes the
device first (disk bank entry 5) and pokes the Meatloaf-class device, or 0, into
KLOAD's `kl_dev` (`$FBA6`); KLOAD compares FA against it and gives everything
else to the stock loader. `test/test_kload_gate.py`.

### 9. `load --slow` -- fold `fload` into `load` -- DONE (v0.2.52)

Fast by default, `--slow` to force the bit-perfect standard-IEC path: the fast
one is the more helpful default. Needs a small shared option parser (there is
none -- `parse_line` just splits on whitespace, so `--slow` arrives as an
ordinary argv entry); it can live in the disk bank, so ~0 resident cost. Worth
doing AFTER the 1541 drive code works, since "fast by default" is a promise we
can only keep for drives we can actually go fast on.

**Done, v0.2.52.** `load` tries the fast path and falls back to standard IEC on
any drive without one, or when the fast load fails -- quietly, so a missing file
still gets the drive's "62 file not found". `load --slow` forces standard;
`fload` stays, as the fast path alone. `run <name>` goes through `load` (it used
to be `fload`, and failed outright on a drive with no fast path). The drive
loader learned `*`/`?` and takes only closed PRGs, so `load *` is fast and a SEQ
of the same name is never claimed. Fitting it in the full disk bank took: the
header send restructured (fastload_drive_install), the loader's variables moved
to BSS, the block length carried in the link field like the cartridge does (454
-> 397 bytes, and one handshake fewer a block: 16KB 9.0 -> 8.8 s). Tried and
reverted: an 8-entry badline table (-248 bytes, +4 cycles a byte, and 16KB went
to 12.2 s -- over the interleave again).

### 6. Type-in support (magazine listings)

Entering a type-in program from a magazine, with the checking those listings were
designed around -- Compute!'s `MLX` for machine code and the Automatic
Proofreader for BASIC. Both are line-at-a-time entry with a per-line checksum, so
a typo is caught on the line you made it on rather than at RUN.

Most of the machinery already exists and the question is which shape to give it:

* **In the hex editor** -- an MLX-style mode: enter a line's bytes, get the
  checksum, compare. It already has the address column, the byte grid, edit marks
  and undo; what it lacks is line-oriented entry and the checksum.
* **In the text editor** -- a proofreader for BASIC listings: show a per-line
  checksum beside each line so it can be checked against the printed one. The
  tokenizer is already there and round-trips byte-exact, which is most of the
  hard part.
* **As a command** -- verify an existing file against a listing's checksums,
  rather than entering it here at all.

Worth pinning down before building: which checksum (there were several -- MLX's
changed between magazines and years), and whether the value is entering listings
on a modern machine at all versus checking a file typed elsewhere. The editors
are the reason this is cheap now; it would not have been before the hex editor
and the tokenizer existed.

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
