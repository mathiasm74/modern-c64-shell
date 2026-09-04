# c64-bootloader (vendored)

A GRUB-style C64 kernal bootloader by **Holger Gryska (r107sl)** — shows a
menu at power-on (hold **C=**, **RUN/STOP**, or **Q**) listing every ROM set on
the One ROM and boots the one you pick; otherwise auto-boots the last choice.

Tardis DOS uses it as loadable ROM **set 0** in the `make onerom-stock`
firmware so you can select Tardis DOS, stock C64, or JiffyDOS at boot
(`cfg/onerom-stock.json`; the per-set menu names come from each set's `label`).

## Provenance

- Upstream: https://github.com/r107sl/c64-bootloader
- Vendored at commit **f6957cb** ("ROM name changed").
- License: MIT (see `LICENSE`) — Copyright (C) 2026 Holger Gryska.

Vendored (rather than using the pre-built binary Piers hosts at
`images.onerom.org/roms/host-control/v0.1.0/c64_bootloader.bin`) because that
**v0.1.0 binary predates One ROM firmware 0.7.x**: its
`GET_FLASH_SLOT_INFO_ALL` response parsing doesn't match the 0.7.x record
format, so the menu fails with "rbcp get flash slot info failed". Building from
this newer source fixes it (bisected on hardware 2026-09-04). If Piers/r107sl
publish a 0.7.x-compatible pre-built binary, this can revert to a URL in the
config and this directory can be dropped.

## Local patch

`main.c` carries ONE local change from upstream (all marked `LOCAL PATCH`):
the menu hides ROM sets whose `label` starts with `~`. Our firmware carries
overlay and alt-font sets that must not be booted directly (booting the Swedish
set gives an English font, since the shell's boot path re-normalises the served
slot to font A), so `cfg/onerom-stock.json` labels those `~overlay a`,
`~Tardis Swedish`, etc. They form a contiguous tail, so the menu clamps the set
count to the first `~`-labelled record, leaving just Tardis DOS / Stock C64 /
JiffyDOS. When re-vendoring a newer upstream commit, re-apply this patch (or
drop it if upstream gains a hide mechanism).

## Build

`make onerom-stock` builds `build/c64_bootloader.bin` from these sources via
`tools/build_bootloader.sh` (cc65, `-t c64`).
