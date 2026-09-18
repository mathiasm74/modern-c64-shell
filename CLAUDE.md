# Tardis DOS — C64 Shell ROM

A ROM-resident command shell for the Commodore 64 that replaces stock BASIC + KERNAL: a 16KB image (two 8KB halves) for a One ROM, EasyFlash or EPROM. Branded **Tardis DOS** ("bigger on the inside": most commands live in banks served on demand).

- Boots into a shell with line editing, history, filename completion; IEC disk commands; built-in Epyx-compatible fast loader; editors.
- Keeps the standard KERNAL entry points so ML software that uses them works.
- **No BASIC interpreter, no tape.** Real software runs by **swapping to the stock ROMs** at launch (`run`/`basic`), via the One ROM Bus Control Protocol (RBCP).
- Targets: C64 PAL/NTSC breadbin (One ROM, main target), C128 in C64 mode, C64C, EasyFlash. Tested in VICE `x64sc` with true drive emulation.

`PLAN.md` has the phased plan and backlog; `docs/` has design notes (RBCP, Epyx receiver, tape space, completion, compatibility, memtest). Git history holds the long-form rationale this file used to carry.

## Toolchain

- **cc65 built from source** (git master), installed to `~/.local` (first on PATH). `cd ../cc65 && git pull && make -j4 && make install PREFIX=$HOME/.local`. The Makefile sets `CC65_HOME` relative to the binary (without it ca65 can't find `longbranch.mac`).
- **`-Cl` (static locals) is on for the resident shell only**, and only when `cc65 --version` says `Git`. Released cc65 (<= V2.19) has [issue #1077](https://github.com/cc65/cc65/issues/1077), which miscompiles under `-Cl` into hardware-only corruption (garbled `help`, broken `cd`, flaky `ls`). If that class of bug reappears, check the compiler version first. Banks never get `-Cl`.
- VICE `x64sc` 3.7+, Python 3, GNU Make. `make check-tools` verifies.

## Build

```
make                 # build/kernal.bin ($E000) + build/basic.bin ($A000, the shell -- not BASIC)
make test            # build + run the suite;  make test M="disk rm" runs matching modules
make test-verbose    # or VICE_VERBOSE=1; VICE_HEADLESS=0 opens the GUI; VICE_JOBS=1 serial
make run             # ./run.sh; DISK=test/data/test.d64 mounts a writable copy (build/run-disk.d64)
make sizes           # per-command exclusive/shared ROM cost (tools/cmd_sizes.py)
make banks           # the bank images
make onerom          # single-bank One ROM image (build-only, no host-control plugin)
make onerom-stock    # the real firmware: boot menu + Tardis + stock + JiffyDOS + banks
make onerom-flash    # build + flash onerom-stock + reboot into running (ONEROM_SERIAL='5*' to pick)
make onerom-c128 / onerom-c64c [-flash]   # combined-ROM targets (see below)
make ef / ef-run     # EasyFlash .crt / run it in VICE
make memtest[-flash] # standalone bus-diagnostic ROM (docs/MEMTEST.md)
make clean
```

Raw 16KB blob: `cat build/basic.bin build/kernal.bin > build/rom16k.bin`. `./run.sh -warp` forwards VICE args; `SKIP_BUILD=1` skips the build. True drive emulation is mandatory: VICE's virtual-device traps hook the stock KERNAL, which we replaced.

**Build gotchas**
- `.include` is invisible to make. Every object that includes `rbcp_defs.s`/`rbcp_config.s`/`bank_cstack.inc`/`kernal_shims.inc` needs an explicit Makefile dependency (`grep -rn '^\s*\.include' src --include='*.s'`). A stale bank image packed into firmware fails only on hardware (`ls` → "bank unavailable"). **If hardware contradicts the source, `make clean` and reflash before believing the source.**
- Make's 1-second mtime granularity can skip a rebuild after a scripted edit. `make clean` when in doubt.
- C128/C64C builds share `build/` and compile with `TARGET_C128`, so run `make clean` before a plain breadbin build.

## Version

Bump on **every build handed to the user**. Format `v0.<minor>.NN`, always 7 chars (e.g. `v0.2.48`) or the right-aligned banner column shifts. Four places: `src/reset.s` (`version` string), `src/ef/platform.s` (the EasyFlash banner's own copy), `src/commands/builtins.c` (`ver`), `test_builtins.py::test_ver_prints_version`. Other tests match the version-agnostic `"Tardis DOS v"`.

## Project layout

```
src/reset.s          reset, hardware init, boot banner, NV colour restore, jump to main
src/irq.s            IRQ (keyboard scan + decode tables, jiffy clock), NMI (RUN/STOP+RESTORE)
src/screen.s         CHROUT, pet2scr, scr_display, cursor
src/kernal_stubs.s   fixed KERNAL entry points ($FFBA-$FFE4)
src/svc.s            SVC table at $FF80 (resident services callable from banks)
src/iec.s            IEC bus driver;  iec_clkwait.s
src/c_io.s           C shims, run_program (sys), run_stub (stock-launch stub)
src/complete.s       filename completion (runs in the util bank)
src/fastload*.s/.c   Epyx protocol, receiver/sender;  drive1541.s  our real-1541 drive code
src/kload.s          fast loader patched into the stock KERNAL's tape space
src/parse_addr.s     number parser for sys
src/shell.c          main loop, readline, history, dispatch table, wedges, settings
src/parser.c         tokenizer
src/commands/        resident commands: builtins.c (ver/clear/reset), fs.c (run/basic/sys/edit/font, bank_dispatch)
src/banks/           bank images: disk (dir.c, disk_bank.c), util (about.s, kbdiag.s, colour.c, picker.c),
                     files (files.c, files_entry.c), edit (edit.c), hex (hex.c); crt0_*.s per bank
src/rbcp/            vendored RBCP 6502 lib + launch.s (swap trampolines, bank_call, NV, font)
src/ef/platform.s    everything EasyFlash-specific
src/memtest/         standalone memtest ROM
cfg/                 ld65 configs (rom.cfg, *_bank.cfg, ef_rom.cfg) + One ROM firmware JSON
tools/               onerom CLI (untracked), build_{c128,c64c,bootloader}.sh, patch_freemem.py,
                     make_ef_crt.py, make_ef_bank_cfg.py, kernal_map.py, cmd_sizes.py
test/                lib/vice.py harness, run_tests.py, test_*.py, data/test.d64 (make_test_disk.sh)
third-party/c64-bootloader/   vendored boot menu (MIT)
stock-roms/, test/corpus/     user-supplied, gitignored
```

## Memory map

| Range | Contents |
|---|---|
| $0000-$008F | shell/cc65 zero page ($02-$1F cc65 regs; banks use $40-$5F; RBCP $80-$8F) |
| $0090-$00FF | KERNAL-standard ZP (see below) |
| $0200-$03FF | KERNAL/shell working memory and mailboxes (see below) |
| $0400-$07FF | screen |
| $0800-$9CFF | user RAM. **Max loaded program end is $9CFF** |
| $9D00-$9FFF | bank RAM window (DATA/BSS/C stack), shared by all banks |
| $A000-$BFFF | shell ROM (BASIC half), or the currently served bank |
| $C000-$CFFF | `line` pinned at $C000 (LINEBUF), shell BSS, RBCP copy at $C800, completion cache $CE00-$CFFF, run stub + mailbox $CE01-$CFFF |
| $D000-$DFFF | I/O |
| $E000-$FFFF | KERNAL half: init, IRQ, CODE2/RODATA2/KCODE, RBCP command page $E0xx, back-channel $FE00 (keep free), SVC $FF80, stubs, vectors |

**KERNAL-standard ZP in use:** `$90` ST, `$94/$95` BSOUR, `$A0-$A2` jiffy clock, `$A3-$A5` IEC scratch, `$B7` FNLEN, `$B9` SA, `$BA` FA, `$BB/$BC` FNADR, `$C5` LSTX, `$C6` NDX, `$D1/$D2` PNT, `$D3` PNTR, `$D6` TBLX, `$F3/$F4` USER, `$F5/$F6` CHROUT save, `$F7-$F9` key-scan scratch (kept disjoint from CHROUT's so an IRQ scan can't corrupt it), `$FB-$FE` string/walk pointers. `$0277-$0280` keyboard buffer, `$0286` text colour.

**Page 2/3 cells worth knowing:** `$02CB` KBD_LAYOUT (0 US / 1 SE), `$02CE` BASE_SLOT (RAM slot the base is served from), `$02BC` PROBEF (IEC probe mode), `$02D0+` files-bank mailbox, `$02D1` device mailbox, `$02C4-$02C7` NV buffer mailbox, `$02B1-$02BB` completion state, `$0340` cd scratch, `$039A/$039C` load_start/load_end (disk-bank mailbox, not copies), `$03A0` argc/argv for banks, `$03A3` completion `anysp`, `$03A4` too-large flag, `$03A5` KL_MEATDEV (the Meatloaf-class device the disk bank's probe confirmed, 0 = none), `$03A6` RECV_PAD. Page 2/3 is power-on garbage: `reset.s` must clear anything whose stale value matters.

## Architecture

### Two ROM halves
- **BASIC half (`CODE`/`RODATA`)**: most cc65 output. Swapped out while a bank runs.
- **KERNAL half (`CODE2`/`RODATA2`/`KCODE`/`RBCP_CODE`)**: always mapped. Anything a bank must reach (SVC targets, the dispatch table *and its name strings*, `bank_call`) lives here.
- Budget pressure moves between halves; `make sizes` and the banner's `Free ROM bytes` (patched by `tools/patch_freemem.py`) show it. The KERNAL half currently carries the stock-KERNAL patch images, so prefer the BASIC half for new resident code. CODE2 must never grow into the `$FE00` back-channel window (`test_rbcp::test_back_channel_window_is_free_fill`).

### Banks
An 8KB image the One ROM serves at `$A000` in place of the BASIC half (`SWITCH_SLOT` to a flash set whose KERNAL+charset are byte-identical to the base, so the swap is live-safe). Bank ABI: `$A000` = `"bnk"`, `$A003` = bank id, `$A004+` = JMP table. `bank_call(id<<5 | entry)` (launch.s, KCODE) swaps, verifies the id, JSRs the entry, and swaps back via `bank_ensure_base` (it checks `$A000` itself instead of trusting the protocol status, retries, and resets as a last resort).

| id | bank | contents | C64 flash set | C128/C64C set |
|---|---|---|---|---|
| 0 | disk | dir, ls, pwd, fload, load (+ run's fast path) | 6 | 2 |
| 1 | util | completion (entry 0), about, debug, border/bg/text + picker | 7 | 3 |
| 2 | files | cat, less, cp, mv, rm, status, cd, peek, poke, help, device, devices, identify | 8 | 4 |
| 3 | edit | text editor + BASIC detokenize/tokenize | 4 | 1 |
| 4 | hex | hex editor | 9 | 5 |

**C64 flash sets** (`cfg/onerom-stock.json`): 0 boot menu, 1 Tardis, 2 stock, 3 JiffyDOS, 4 edit, 5 Tardis+Swedish font, 6 disk, 7 util, 8 files, 9 hex. **C128/C64C:** 0 Tardis, 1 edit, 2 disk, 3 util, 4 files, 5 hex, 6 stock. The numbers are encoded in `bank_flash_set` + `RBCP_STOCK_FLASH_SLOT` (launch.s) and `FONTB_FLASH_SET` (fs.c). A bank set is `[kernal | charset | bank]`; to add or move one, copy the layout of another bank set, because a set wired in the wrong chip order passes the build and fails on hardware (`test_rbcp::test_bank_flash_sets_have_the_right_chip_layout`).

**Rules for banks**
- **Only the KERNAL half is reachable from a bank**, for code (via SVC `$FF80` and the `$FFxx` stubs) *and* for data a bank follows. `shell.c` pushes `rodata-name` to `RODATA2` and never pops it, deliberately, so the dispatch names land in the KERNAL half. A stray pop makes `help` print garbage on hardware only (`test_shell::test_command_names_live_in_the_kernal_half`).
- **A bank cannot call another bank.** Things that call each other (a command and the picker it opens) must share an image. Code that has to choose between banks (`edit`'s file sniff) is resident.
- Bank RAM belongs to the bank only while it runs: `bank_init` redoes zerobss/copydata on every C entry. Asm-only entries (completion, about, debug) skip it.
- Entry numbers live in `crt0_*.s` (JMP order), `shell.c` dispatch rows and `fs.c` (`identify_boot_device`), and nothing ties them together. `test_rbcp::test_bank_entry_indices_match_the_entry_tables` guards identify.
- **Adding a command:** add a sorted row to `shell_commands[]` in `shell.c`. A bank command is `{ "name", BANK_CMD(bank, entry) }` (handler < $0100 means a bank index) and costs the 16KB ROM only its row and name. The bank reads argc/argv from `$03A0` and prints its own errors. Default new commands into a bank with room.
- **VICE testing:** the RAM under `$A000` receives writes, so `bank_call` falls back to running a bank from there when no One ROM answers (magic-guarded). Tests seed one bank at a time with `seed_disk_bank`/`seed_util_bank`/`seed_files`/…; a test that crosses banks must re-seed.

The old RAM overlays (`$8800`, `mp_fetch`) are **gone** since v0.2.09. `$8800-$8803` is ordinary user RAM, so don't reintroduce cache invalidation there.

### RBCP / One ROM
- Commands are *reads* of the command page (`$E0xx`; `$A0xx` on combined-ROM targets). A VIC badline stalls the CPU mid-read and the device counts duplicate bytes, so every frame waits via `rbcp_vic_guard` for a badline-free window (assumes YSCROLL=3, no sprites).
- New C-callable RBCP op: the **entry point goes in `KCODE`** (runs from ROM, calls `copy_to_ram`), the **trampoline goes in `RBCP_CODE`** (runs from the RAM copy at `$C800`). An entry point in RBCP_CODE hangs the boot.
- **Boot menu:** set 0 is r107sl's `c64-bootloader`, built from source (`tools/build_bootloader.sh`) because the hosted v0.1.0 binary fails on firmware 0.7.x. Hold C= / RUN/STOP / Q at One ROM cold boot, or **hold C= in a running shell** (`_rbcp_launch_bootmenu`). The menu hides sets labelled with a `~` prefix (LOCAL PATCH in the vendored `main.c`; read `rbcp[]` through a `volatile` pointer and compare raw `0x7E`, because cc65 translates `'~'` to PETSCII).
- **NV settings** (colours, history, font) live at NV offset 16 (`NV_BLOB_BASE`). Blob format v3: `"TD"`, version, 3 colours, font, vestigial prompt, history. `reset.s` applies colours before display-on; `settings_load()` is inert when NV is absent. Saves happen on a colour change, every 8 commands, after a ~5 s idle with unsaved commands, on `font`, `basic` and `reset`. **Reflashing wipes NV** (expected).
- **Stock-KERNAL patching via `SLOT_POKE`** at swap time, after `LOAD_SLOT` and before switching (~588 µs/poke). Patches applied: Swedish keyboard tables (`$EB81`/`$EBC2`, when KBD_LAYOUT=1), text colour (`$E535` immediate), the **KLOAD fast loader** into tape space `$F8E2-$FB8D` + tables at `$FBA6` with ILOAD repointed in the ROM vector table `$FD4C` (last, and only if every body poke succeeded). KLOAD fast-loads **only** the device in its `kl_dev` byte (`$FBA6`), which the swap pokes from `$03A5` after a fresh disk-bank probe (entry 5, `fs.c probe_for_kload`); anything else goes to the stock loader, because its fast path M-E's fingerprint filler that a real 1541 would execute and hang on (`test_kload_gate`). Also patched: the **`EXIT` wedge** at `$F533` hooked via BASIC's vector table `$E44F`. Slot offsets are KERNAL-first (`$E000` = offset 0). Tape-space map: `docs/TAPE-SPACE.md` (`tools/kernal_map.py`). `$FB8E-$FBA5` is live stock code, so overflow into it corrupts the stock KERNAL without a link error. Tests check each piece against its own run.
- RBCP swaps are **inert in VICE**: the swap, the menu, font, NV and served banks are hardware-only.

### Launching stock software (`run`, `basic`)
- `run <name>` fast-loads (disk bank) and then swaps; bare `run` re-runs `load_start/load_end`. `basic` swaps with any loaded program kept (READY mode); `basic <line>` (up to 80 chars, captured raw by `capture_basic_tail()` before the tokenizer mangles quotes) executes the line at the stock prompt through BASIC's own input buffer `$0200`, entering MAIN at `$A48A`.
- `_rbcp_launch_stub` plants a CBM80 at `$8000` and falls through to `_rbcp_launch_stock`. The stock reset autostarts `run_stub` (copied to RAM, `RUN_STUB_BASE`, exported from `c_io.s`), which does IOINIT/RAMTAS/RESTOR/CINT, restores `$BA`, sets up BASIC like stock LOAD (including **LINKPRG `$A533`**), then types `RUN` or drops to READY. ML programs `JMP` to their load address.
- The stub **consumes the CBM80 on entry** (gated on `RUN_CBM80`; EF plants none), or any later reset replays the launch.
- **The stub may contain only PC-relative branches internally.** A `jmp label` assembles our ROM address, which is gone after the swap; write `RUN_STUB_BASE + (label - _run_stub)` (`test_run_stub_has_no_absolute_jumps_into_our_rom`). The stub has little headroom below `$D000`, and overflow writes VIC registers.
- Returning to Tardis: RUN/STOP+RESTORE (NMI → `rbcp_nmi_escape`), typing `EXIT` at the stock prompt, a program ending (`$0302` hook), or C= at cold boot. A bare `basic` with nothing loaded cold-swaps and has no escape.

### KERNAL entry points

Fixed JMPs defined in `src/kernal_stubs.s`, placed by per-entry segments in `cfg/rom.cfg`. Update both and this table when adding one.

| Addr | Routine | Addr | Routine |
|---|---|---|---|
| $FFBA | SETLFS | $FFCC | CLRCHN |
| $FFBD | SETNAM | $FFCF | CHRIN |
| $FFC0 | OPEN | $FFD2 | CHROUT |
| $FFC3 | CLOSE | $FFD5 | LOAD |
| $FFC6 | CHKIN | $FFD8 | SAVE |
| $FFC9 | CHKOUT | $FFE4 | GETIN |

Single-file model (most recent SETLFS is the current file). LOAD always uses bus channel 0; SA=0 honours the file's address, SA≠0 uses X/Y. CHRIN preserves X/Y. CHROUT after CHKOUT goes to IEC with the stock one-byte deferral (WRPEND `$94`/WRBYTE `$02BE`) so CLRCHN sends the last byte with EOI. The hardware vectors at `$FFFA` must point into `reset.s`/`irq.s`. `test_kernal_io.py` covers them.

## Subsystems (the non-obvious parts)

**Screen/charset.** The lowercase charset (`$D018=$16`) with an ASCII-consistent encoding: `pet2scr` maps `'a'`→`$01`, `'A'`→`$41`, `$A0-$BF`→`$60-$7F`, `$C0-$FF`→`$40-$7F`. CHROUT ignores `$80-$9F`. `scr_display` (SVC 12) adds the reverse-video quote-mode rule for control codes (`$00-$1F`→`c`, `$80-$9F`→`(c&$1F)+$40`; plain `c&$7F` is wrong because it collides colour pairs). The cursor is a static reversed cell. Boot colours: light-red border `$0A`, dark-red bg `$02`, white text (`test_memory.py`); NV overrides them.

**Keyboard** (`irq.s`). `SHFLAG` bitmask (bit0 shift, bit1 C=, bit2 CTRL) selects between `keytab`/`keytab_shift`/`keytab_cbm` (the last transcribed from the real KERNAL's `$EC03`, checked by `test_keyboard::test_cbm_table_matches_the_kernal`) and `keytab_se`/`keytab_se_shift` when KBD_LAYOUT=1. CTRL+letter emits `$01-$1A`, CTRL+1..8 colour codes, and a **bare CTRL tap emits TAB** (completion). `@`+C= stays `_` for VICE's symbolic keymap. Repeat applies to all keys. Every `$DC00` select needs a settle gap before the `$DC01` read (a test enforces this). The matrix scan itself is hardware/GUI-only; the tables are tested from ROM via `build/labels.txt`. If a key row dies on hardware, suspect the joystick (autofire latch on PA4) first; `debug` shows the raw matrix.

**Line editor** (`readline`, shell.c). Cursor left/right, insert, DEL (wraps across rows), HOME = input start, CLR = wipe input, 8-entry history on up/down. Wedges (`wedge_rewrite`, after `history_add`): `@`=status, `@$`=dir, `@#n`=device n, `/x` `%x`=load, `^x`=run (the rest of the line is quoted).

**Completion** (`complete.s`, util bank entry 0; rules in `docs/TAB-COMPLETION.md`). Matches names in the `$CE00-$CFFF` cache that `ls`/`dir` fill. It quotes as soon as any candidate has a space (including `$A0`) and closes the quote on a unique full match. It is silent if no bank answers. The cache is invalidated by cd/device/rm/mv/cp/SAVE, overlapping loads, dir errors, boot and the run stub. In the insert loop, test `kins == 0` before `dec`.

**IEC** (`iec.s`). IRQs are masked per byte. A 1541 sends a real last byte with EOI; Meatloaf/SD2IEC go idle and `iec_getbyte` synthesizes `$00`+EOI, which consumers must not store. The first send handshake times out (~0.7 s) → ST `$80` "device not present", then broadcasts UNLISTEN/UNTALK. Other send waits are unbounded except in **probe mode** (`PROBEF`), which is used only for presence and identity scans (`device`, `devices`, boot identify). Never use probe mode for transfers. Reads time out (~1.4 s) → "read error". Filenames are uppercase-folded. `iec_setname` caps names at 40 chars.

**Disk commands.** `load` is fast by default: it tries the Epyx path and, if the drive has none or the fast load fails, quietly loads over standard IEC, which reports the drive's own error (`load --slow` forces standard; `fload` is the fast path alone and says when it can't; `run <name>` is `load` then run; `test_load_default`). `ls`/`dir` are fast on a Meatloaf only, standard elsewhere; `pwd` is standard (paging via CTRL waits safely). Tapping CTRL during a listing arms `-- more --` paging. `ls` shows two coloured columns, coloured by what you can do with the file (`type_color`, dir.c): PRG light green, DIR/URL/D64-style entries yellow, SEQ/USR the user's text colour, REL/DEL grey (`test_ls_colors`). `pwd` tries the drive's `PWD` command and falls back to the header/NFO lines. `cd`/`mv`/`rm` send `CD:`/`R0:`/`S0:` via channel 15 and report non-00 status (`rm` checks the scratched count). `device n [name]` probes the unit first, and names come from `UI` identity. The prompt is `8: meatloaf> `.

**Fast loading.**
- The Epyx receiver (`fastload_recv.s`) is cycle-timed and **paces around badlines**, so the screen stays on (`docs/EPYX-RECEIVER.md`). Wait for the drive *before* choosing the raster offset.
- Our Epyx install payload is fingerprint filler that only **Meatloaf** accepts. `fastload_epyx_capable()` must gate installing that payload, or a real drive `M-E`s into the `$EA`s and hangs until reset (reproducible in VICE with true drive emulation).
- `drive1541.s` is our own real-1541 drive-side loader, and in VICE it matches a real Epyx cart (16KB 9.0 s vs 9.3 s; `test_fload_speed` guards it). It goes up in two stages: `drive1541_boot.s` (78 bytes, M-W'd to `$0400`) clocks the loader into `$0500` over the host→drive Epyx send, with the filename patched into its header. The bootstrap is told the loader's size at build time (`-D LDRSIZE`). Its variables are BSS (not uploaded), the block's length byte rides in the sector's link field, and its lookup takes only closed PRGs, with `*`/`?` wildcards; anything else falls to the drive's own lookup via `load`'s fallback. **The disk bank is full**: the 256-entry `badtab` cannot shrink to 8 (+4 cycles a byte misses the interleave, 9.0 → 12.2 s).
- What made it fast (PLAN.md §8): **kick VIA2 T1 (`$1C05`) when posting a job**, or the job waits for the next 14.8 ms controller tick; the badline gate blocks only offsets `YSCROLL-1..YSCROLL` (a third one made every other sector miss the interleave); no `I0` (on job error `$0B` the loader copies the header ID `$16/$17` to `$12/$13` and retries); a seek to track 18 posted by M-W before the upload, so the motor spins up during it.
- Drive facts: the 1541's input bits are inverted, CLK high = ready (hold CLK low while busy), `php`/`plp` must not straddle `jsr`/`rts`, and pairs are spaced 10 cycles, the Meatloaf timing, so one receiver serves both. To trace the drive, set `break 8:<addr>` and keep the monitor socket open across `x`; the drive stopwatch gives per-sector timing.
- `load`/`fload` refuse programs past `$9CFF` ("program too large"); `fload`'s guard rides the page crossing (`BANKPG`). `test_rbcp::test_bank_ram_ceiling_and_loader_guards_agree`.
- KLOAD (the stock-side wedge) handles both SA forms; SA=0 relocates to MEMUSS `$C3/$C4`. VERIFY and failures fall back to stock `$F4B8`. The stock `CIOUT` clobbers X but preserves Y. It matches a real Epyx cart on Meatloaf (~14 s vs 38 s). Multi-load titles are still unvalidated.

**Editors.**
- `edit <name>` sniffs the file (resident, fs.c): tokenized BASIC (`$0801` + forward link) or text goes to the edit bank, binary to the hex bank; no name opens a new document.
- The text editor wraps long lines and lists and saves BASIC with its own keyword table. Tokenizing is first-match in table order and suspended in quotes, after REM, and after DATA until the next colon. It refuses out-of-order lines. `^V` inserts the next key literally.
- The hex editor loads the whole file into `$0800`, is overwrite-only, marks edited bytes yellow with a sparse chunk map past the document, and has `^Z` undo (128 records; clears marks when no remaining record touches the byte), `^B/^F/^G/^W`, and `^` to switch panes. Bindings must be control codes.
- Both editors ask nano's exit question (`y` save, `n` discard, other = cancel); `test_hex::test_both_editors_ask_the_same_question_on_exit`. Tests answer `n`.

**Font / Swedish** (`font [0|1]`, resident, RBCP-only). Font B = flash set 5 loaded into RAM slot 2 and switched to (never LOAD into served slot 0). `BASE_SLOT` records it so `bank_restore` switches back to the right slot. Sets KBD_LAYOUT with it; the choice persists in NV. Swedish ä/ö/å are PETSCII `$5B-$5D`, Ä/Ö/Å `$DB-$DD` (readline and CHROUT accept them). The matrix positions are hardware-unvalidated; adjust `keytab_se*` if a keycap lands elsewhere.

**Other commands.** `sys <addr>` JSRs in the *current* environment (decimal, or `$hex`; for SIDKick triggers etc.) and is resident on purpose. `peek`/`poke` use the same number rule. `status` reads channel 15 as `<code> <message>` with exactly one newline. `border`/`bg`/`text` with no value open the picker (the text preview repaints rows 0-4 only). `debug` is the raw keyboard matrix viewer (keep one spare screen row; print long strings with a 16-bit pointer, not `,x`). RUN/STOP+RESTORE in the shell = soft reset.

## Other targets

**C128 (C64 mode, U32) and C64C** (`tools/build_c128.sh`, `build_c64c.sh`): one combined 16KB `[BASIC|KERNAL]` 23128 on a 28-pin One ROM (C128 `fire-28-c`; C64C default `fire-28-a`, `C64C_BOARD=` to override). CS mask `cs1/cs2=active_low, cs3=active_high`. `TARGET_C128` means "combined image": it skips boot-time RBCP (whose handshake hangs before display-on), remaps the command page to `$A0` with the back-channel ROM offset `$3E00`, and sets stock = set 6. 8KB bank sets use `size_handling=duplicate` to 16KB. No char ROM, so `font` reports unavailable. Needs a true power-off cold boot after flashing. `reset.s` disables VIC IRQs unconditionally, because a raster IRQ carried over by `GO64` livelocked the machine. C64C is not yet validated on real silicon.

**EasyFlash** (`make ef` → `build/ef/tardis.crt`). This is the only target where banking, the handover and `run`/`basic` round trips are testable in VICE (`test_ef_*.py`; VICE's jumper sense is inverted). ROML `$8000` = the KERNAL-half code, ROMH `$A000` bank 0 = shell, banks 1-5 = disk/util/files/edit/hex, relinked from the same objects (`-D EF_BANK=1`, cfgs generated by `tools/make_ef_bank_cfg.py`). Fixed tables move `$Fxxx`→`$9xxx` (SVC `$9F80`, CHROUT `$9FD2`, …); `$0326`/`$032A` point at those entries. Rules:
- `$DE00` banks both windows, so **every bank carries a byte-identical ROML**.
- **No self-modifying code in ROML**; use cartridge RAM at `$DF00` (bank_call's jsr, escape hatch at `$DF40`).
- A mode switch can't run from the window it switches; copy a stub out first.
- The `$0314` hook exits via `$EA81`, not `RTI` (`irq_tick` + per-entry shims).
- `ef_cold` must re-apply `$D018`/`$D016`/colours after the stock CINT.
- Bank RAM is `$C800-$CDFF` (the One ROM's `$9Dxx` window is inside ROML here). `$C000-$CFFF` is full, with ~140 bytes spare.
- `run`/`basic` turn the cartridge off *before* the stub runs (else MEMSIZ = `$8000`).
- No `font`, no NV, and no typed `EXIT` (RUN/STOP+RESTORE instead).

**Kung Fu Flash: works (v0.2.52)** -- boot, banks, fast `load`/`fload` and the `run`/`basic` round trips all behaved on real hardware. But the reboots are flaky: sometimes the screen stays black and the KFF menu is unreachable. Not yet investigated. Ultimate is still untested.

## Testing

`test/lib/vice.py` `Vice` launches headless `x64sc` with the remote monitor: `read_memory`/`write_memory`, `screen_text`/`screen_rows`/`screen_cells`, `registers`/`pc`, `inject_keys` (keyboard buffer, ≤10 chars), `run_at(addr, s)`, and `assert_*` helpers. Tests are `test_<name>(v)` functions in `test_*.py`. One VICE per module, run in parallel (≤6 workers), longest-first from `build/test-times.json`; the full suite is a few minutes and a single module takes seconds.

- Poll instead of sleeping: loop `run_for` until the text appears, and poll NDX `$C6` to 0 after injecting keys. `_drain` is prompt-aware (`_PROMPT_RE`).
- Screen RAM holds screen codes; use `screen_text()`. It masks bit 7 and decodes graphics as `.`, so assert raw codes when those matter. `screenshot()` needs a GUI.
- Disk-mutating tests work on a scratch copy of the fixture made at import, never on `test/data/test.d64`. The harness detaches the disk before quitting so writes flush.
- `run_at` parks the CPU; such tests get their own module or reboot via the reset vector.
- Hardware-only (inert in VICE on the One ROM target): RBCP swaps, served banks, font, NV, boot menu, the live keyboard matrix, Meatloaf-specific paths.
- Add a test with every feature, preferably a new one rather than editing existing tests. Verify a regression test fails without the fix, since several here passed against the bug on their first version.
- `test/corpus/` (gitignored) holds software images; results go in `docs/COMPATIBILITY.md`.

## Conventions

- Asm in `src/*.s` for hardware, IRQ, fixed-address and timing-critical code; C for shell logic and commands. C-callable asm is `.export _name`.
- Names: asm labels and C functions `lower_snake`; asm constants `UPPER`; command handlers `cmd_<name>`.
- cc65: access fixed mailbox cells by absolute address (`*(unsigned char*)0x02D2`), not through a base-pointer macro. Keep 2D array rows power-of-two (`hist` 64, `device_name` 16) to avoid pulling in `mul`.
- Commits: short imperative subjects ("add CHROUT entry point"). Commit after passing tests; keep `make test` green (or mark expected failures with a reason).

## Status

Phase 9 (software compatibility) is in progress; see PLAN.md for the backlog (multi-load validation of KLOAD, `fload` on a real 1541 (VICE-validated only), a 1541 path for KLOAD, `load --slow`, type-in support). AUTOEXEC is deferred: boot-time IEC can still wedge on a drive that isn't ready.
