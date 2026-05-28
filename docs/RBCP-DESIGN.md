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

1. **A RAM trampoline + `cmd_runstock` (or rebrand `cmd_run`).** The library
   must execute from RAM (the ROM under the CPU vanishes mid-call). The flow
   is: load the program into user RAM; copy the RBCP routines + a tiny
   launcher to RAM; `SEI`; `JSR rbcp_reset` -> `JSR rbcp_cmd_enter_cmd_resp`
   -> `JSR rbcp_cmd_load_slot` (flash 3 -> a RAM slot) -> `JSR
   rbcp_cmd_switch_and_exit`; finally `JMP ($FFFC)` (so stock KERNAL's reset
   takes over and the cart-style autostart path runs), or `JMP entry` for an
   ML program that doesn't need stock-KERNAL init.

2. **Stock ROM bytes.** `test/data/c64-{kernal,basic}.bin`. Not in the repo;
   the user provides them.

3. **Hardware validation.** VICE has no One ROM model, so the actual swap
   can only be confirmed on a real One ROM. We can verify in VICE that the
   shell emits the expected reads in the expected order via a memory watch,
   but the swap itself only happens on the device.

4. **Return-to-shell path.** RBCP's `RBCP_RESET` resets the *device's*
   protocol state, not the host. Returning from a launched program to the
   shell currently requires a power cycle (the device boots back to slot
   2 = the shell). A future plugin-side "host reset" command would let us
   wire a soft return; worth asking about.

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
