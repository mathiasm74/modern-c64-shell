# Stock-ROM bank swap via RBCP

Phase 9 finding (see `docs/COMPATIBILITY.md`): with our shell ROM as the only
environment, the corpus mostly fails because real software calls into stock
C64 BASIC and KERNAL routines we don't (and can't economically) reimplement.
The right answer is to keep the shell as a launcher and **hand off to stock
ROMs when running an external program**.

This is feasible on One ROM via the **`user/host-control` plugin**, which
implements the [ROM Bus Control Protocol (RBCP)][rbcp]. A C64 program in
command-response mode can issue `SWITCH_AND_EXIT` to make One ROM serve a
different image slot at runtime; on the next instruction fetch, the C64 sees
the new ROM.

[rbcp]: https://github.com/piersfinlayson/rom-bus-control-protocol

## How the pieces fit

```
One ROM flash slots:
  slot 0  system/usb plugin           (always; needed to flash/reboot)
  slot 1  user/host-control plugin    (RBCP -- new)
  slot 2  our shell (multi: kernal.bin + basic.bin)        ← boot
  slot 3  stock C64 (multi: c64-kernal.bin + c64-basic.bin)
```

`cfg/onerom-stock.json` builds this. `make onerom-stock` requires stock
C64 ROMs at `test/data/c64-{kernal,basic}.bin` -- they're freely
redistributable from Commodore's released sources; drop them in yourself.

## RBCP integration

The 6502 reference library is vendored at `src/rbcp/`:

- `rbcp.s` -- the routines. Segment retargeted to `RBCP_CODE` so it lands
  in our KERNAL ROM ($Exxx) rather than squeezing the BASIC ROM.
- `rbcp_defs.s` -- protocol constants (group/cmd codes, knock sequence,
  back-channel offsets).
- `rbcp_config.s` -- our platform configuration:
  - Command page at `$E0` (reads in `$E0xx` are commands when in CR mode).
  - Back-channel at `$E100-$E2FF` (512 bytes, response header + data).
  - 16 bytes of zero page at `$80-$8F` (clear of cc65 pseudo-regs at
    `$02-$1B` and our `iec.s` working set at `$90+`).

All the routines are exported; we link only what's referenced.

## What still has to land

1. ~~**A RAM trampoline + `cmd_runstock`.**~~ **Done.** `src/rbcp/launch.s`
   has the launcher (`_rbcp_launch_stock`, KCODE) and the RAM-side trampoline
   (in `RBCP_CODE`). The launcher copies the whole library block from ROM
   ($Exxx) to RAM ($C800), then `JMP`s into the in-RAM trampoline. The
   trampoline does `SEI -> rbcp_reset -> enter_cmd_resp -> load_slot
   (3 -> RAM slot 1) -> switch_and_exit -> JMP ($FFFC)`. Going through the
   stock-KERNAL reset vector lets stock IOINIT/RAMTAS/CINT clean up the
   state our shell left behind ($D018 charset bank, IRQ vector, screen
   contents) -- a direct `JMP load_start` instead skipped all that and put
   the user in front of a half-initialized stock environment, with our
   shell's banner ghosting through and scattered `$A0` reverse-video
   artifacts from garbage execution (the first-hardware-test finding).
   `cmd_runstock` in `fs.c` is the C-side glue (in CODE2 / KERNAL ROM to
   fit the BASIC ROM budget); the dispatch table has a new `runstock`
   command. The loaded program survives the reset in RAM at `load_start`,
   so `RUN` from the stock BASIC prompt picks it up. `test_rbcp.py`
   verifies the segment layout and the copy step.

2. ~~**Stock ROM bytes.**~~ **Provided** at `stock-roms/basic.901226-01.bin`
   and `stock-roms/kernal.901227-03.bin` (gitignored). `make onerom-stock`
   builds the 4-slot firmware.

3. **Hardware validation.** Still pending. VICE has no One ROM model -- the
   reads at the command page are inert there, so the trampoline issues the
   correct protocol bytes but the device-side swap never happens; the SEI'd
   CPU then hangs in the protocol's poll loop. On a real One ROM with the
   `user/host-control` plugin in slot 1, the device should see the commands
   and serve slot 3 (stock ROMs) on the next instruction fetch.

4. **Return-to-shell path.** RBCP's `RBCP_RESET` resets the *device's*
   protocol state, not the host. Returning from a launched program to the
   shell currently requires a power cycle (the device powers up back to
   slot 2 = the shell). A future plugin-side "host reset" command would let
   us wire a soft return; worth asking Piers about.

5. **Picking the right RAM slot.** The launcher hard-codes `RAM slot 1` as
   the target of `load_slot`. The reference bootloader does the same, but
   it's a guess until hardware testing tells us whether slot 1 is always
   safe or whether we need to call `rbcp_cmd_get_ram_slot_info_all` first to
   find a free one. Easy to swap in; tracked as a follow-up.

6. **Autostart.** `runstock` currently lands at the stock BASIC `READY.`
   prompt and expects the user to type `RUN` to start a loaded `.prg`.
   Cleaner: plant a `CBM80` autostart stub at `$8000-$8009` before the
   swap (cold-start vector + signature + a tiny `JMP load_start`); stock
   KERNAL's reset detects the signature and JMPs through the cold vector,
   running the program automatically. Easy follow-up once the swap itself
   is fully validated.

## What we did in this session

- Vendored `rbcp.s`/`rbcp_defs.s` into `src/rbcp/`, retargeted to
  `RBCP_CODE` (KERNAL ROM, where we have slack).
- Wrote `src/rbcp/rbcp_config.s` for our memory map (command page at
  `$E0`, BCH at `$E100`, ZP block at `$80`).
- Added the `RBCP_CODE` segment in `cfg/rom.cfg`.
- Created `cfg/onerom-stock.json` with the host-control plugin and a
  stock-ROM chip_set (slot 3).
- Added `make onerom-stock` (builds only when the stock ROM files exist).
- All this builds clean -- the library is integrated, the firmware config
  is ready. The C-side launcher and the hardware test are the next pieces.
