#!/bin/sh
# Build the Commodore 128 firmware: Tardis DOS as the C64-mode ROM in socket
# U32, so GO64 gives you the shell while C128 mode stays stock. See the "C128 /
# C64-mode port" notes in CLAUDE.md for the how and why.
#
# The C128 shell is compiled with -D TARGET_C128, which (a) skips all boot-time
# One ROM RBCP -- the boot-menu/font/NV features don't apply and would hang --
# and (b) remaps the RBCP command page to $A000 (image offset 0, where the
# plugin watches) since the served 16KB image is [BASIC $A000 | KERNAL $E000].
#
# NOTE: this shares the build/ tree with the normal C64 build but compiles with
# different flags, and make doesn't track flag changes -- so it `make clean`s
# first, and you must `make clean` again before a subsequent plain (C64) build.
#
# The served image is a single 23128 (16KB). Firmware 0.7.x sizes RAM slots to
# the served ROM, so the overlay flash sets are duplicated 8KB->16KB (23128) to
# match, or LOAD_SLOT refuses them. Overlay set numbers: OVL_C128=1 (set by the
# Makefile from EXTRA_DEFS) makes gen_overlay_pages.py emit sets 1/2/3.
set -e

BOARD="${ONEROM_BOARD:-fire-28-c}"
FW="${ONEROM_FW_VERSION:-0.7.1}"
# Versioned like every other artifact, so a release asset needs no renaming.
VER=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' src/commands/builtins.c | head -1)
OUT="build/tardis-c128-${VER}-for-onerom-${BOARD}.bin"

# CS polarities for the 325182 (23128) in the C128 U32 socket, same as the
# C64C's 251913 (same CBM 23128 mask): cs1/cs2 active-low, cs3 active-high.
CS="cs1=active_low,cs2=active_low,cs3=active_high"

# Stock C64 set (loadable set 4) that `basic`/`run` swap to: the C128's own
# C64-mode ROM (325182 = [C64 BASIC | C64 KERNAL], the chip that was in U32),
# fetched from Zimmers. Same [BASIC][KERNAL] 16KB layout as our served image, so
# after the swap C64 mode is genuine stock C64 BASIC (power-cycle to return to
# Tardis). RBCP_STOCK_FLASH_SLOT=4 in launch.s (TARGET_C128) points here.
STOCK_C64="https://www.zimmers.net/anonftp/pub/cbm/firmware/computers/c128/c128_c64part.325182-01.bin"

echo "== clean + build C128 shell (TARGET_C128) =="
make clean >/dev/null
make EXTRA_DEFS='-D TARGET_C128' \
     build/rom16k.bin build/overlays_a.bin build/overlays_b.bin \
     build/banks/disk_bank.bin build/banks/util_bank.bin build/banks/files_bank.bin

echo "== assembling firmware ${OUT} (board ${BOARD}, fw ${FW}) =="
tools/onerom firmware build --board "$BOARD" --version "$FW" \
  --plugin usb --plugin host-control \
  --slot "file=build/rom16k.bin,type=23128,$CS" \
  --slot "file=build/overlays_a.bin,type=23128,$CS,size_handling=duplicate" \
  --slot "file=build/overlays_b.bin,type=23128,$CS,size_handling=duplicate" \
  --slot "file=build/banks/disk_bank.bin,type=23128,$CS,size_handling=duplicate" \
  --slot "file=build/banks/util_bank.bin,type=23128,$CS,size_handling=duplicate" \
  --slot "file=build/banks/files_bank.bin,type=23128,$CS,size_handling=duplicate" \
  --slot "file=${STOCK_C64},type=23128,$CS" \
  --out "$OUT"
echo "  c128 fw : $(wc -c < "$OUT" | tr -d ' ') bytes -> $OUT"
echo "  (remember: 'make clean' before a plain C64 build -- shared build/ tree)"
