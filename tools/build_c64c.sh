#!/bin/sh
# Build the Commodore 64C firmware: Tardis DOS for a C64C's SINGLE combined
# KERNAL+BASIC ROM (251913, one 28-pin socket), served by a 28-pin One ROM
# (default fire-28-a). See the "C64C port" notes in CLAUDE.md.
#
# WHY this differs from the normal C64 build (make onerom-stock, fire-24-e):
# the breadbin C64 has SEPARATE 24-pin KERNAL (U4) and BASIC (U3) 2364 sockets,
# so that build serves them as a MULTI-ROM set over two chip-selects -- which
# needs the One ROM's X1 pin. A 28-pin board like fire-28-a has NO X1, so it
# cannot do multi-CS sets. The C64C's ROM is instead ONE combined 16KB chip
# (251913 = [C64 BASIC $A000 | C64 KERNAL $E000]), served as a SINGLE ROM (one
# CS) -- which the 28-a handles fine, including the loadable overlay sets.
#
# The combined-16KB layout is exactly the C128 U32 case, so this reuses the
# TARGET_C128 build mode. Despite the name it is the "single combined ROM image"
# mode, not C128-machine-specific: it remaps the RBCP command page to $A000
# (image offset 0 in a [BASIC|KERNAL] image), puts the stock-swap set at flash
# slot 4, and skips boot-time RBCP (NV colour restore / boot-device probe / C=
# menu), whose handshake hangs before display-on on the combined layout. (The
# only genuinely C128-motivated change, the VIC-IIe IRQ disable in reset.s, is
# unconditional and harmless on a C64C.)
#
# No char ROM is served (a 2nd chip would reintroduce the multi-CS/X1 need), so
# `font` reports "font switch unavailable" and the charset stays the boot font.
# Everything else works: the overlays (cat/less/cp/mv/rm/cd/dir/edit/...) fetch
# over RBCP at command time, and `run`/`basic` swap to the stock C64 set.
#
# HARDWARE-ONLY to validate, and NOT yet confirmed on real C64C silicon -- only
# in C128 C64-mode, which is the same combined-ROM path. Sanity-check boot plus
# a couple of overlay commands after flashing.
#
# Shares the build/ tree with the normal build but compiles with different
# flags (make does not track flag changes), so it `make clean`s first -- and you
# must `make clean` again before a subsequent plain (breadbin) C64 build.
set -e

BOARD="${ONEROM_BOARD:-fire-28-a}"
FW="${ONEROM_FW_VERSION:-0.7.1}"
# Generic on purpose: this was pinned to v0.1.* and silently produced an
# unversioned filename the moment the version rolled to v0.2.00.
VER=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' src/commands/builtins.c | head -1)
OUT="build/c64c-tardis-dos-${VER}-for-onerom-${BOARD}.bin"

# CS polarities for the 251913 (23128) in the C64C's ROM socket: the CBM 23128
# mask -- cs1/cs2 active-low, cs3 active-high (same as the C128 U32 325182).
CS="cs1=active_low,cs2=active_low,cs3=active_high"

# Stock C64 swap set (loadable set 4) that `basic`/`run` swap to: genuine stock
# C64 [BASIC | KERNAL], concatenated from the user-supplied stock ROMs (same
# 16KB [BASIC][KERNAL] layout as the served image). RBCP_STOCK_FLASH_SLOT = 4
# (TARGET_C128) points here; power-cycle to return to Tardis after a swap.
STOCK_BASIC="stock-roms/basic.901226-01.bin"
STOCK_KERNAL="stock-roms/kernal.901227-03.bin"
STOCK_OUT="build/stock-c64-combined.bin"

echo "== clean + build combined image + overlays (TARGET_C128 = combined-ROM layout) =="
make clean >/dev/null
make EXTRA_DEFS='-D TARGET_C128' \
     build/rom16k.bin build/overlays_a.bin build/overlays_b.bin \
     build/banks/disk_bank.bin build/banks/util_bank.bin build/banks/files_bank.bin

if [ ! -f "$STOCK_BASIC" ] || [ ! -f "$STOCK_KERNAL" ]; then
    echo "ERROR: stock C64 ROMs not found ($STOCK_BASIC / $STOCK_KERNAL)." >&2
    echo "       Put the user-supplied stock ROMs in stock-roms/ (gitignored)." >&2
    exit 1
fi
echo "== stock C64 swap set: [BASIC|KERNAL] combined =="
cat "$STOCK_BASIC" "$STOCK_KERNAL" > "$STOCK_OUT"

echo "== assembling firmware ${OUT} (board ${BOARD}, fw ${FW}) =="
tools/onerom firmware build --board "$BOARD" --version "$FW" \
  --plugin usb --plugin host-control \
  --slot "file=build/rom16k.bin,type=23128,$CS" \
  --slot "file=build/overlays_a.bin,type=23128,$CS,size_handling=duplicate" \
  --slot "file=build/overlays_b.bin,type=23128,$CS,size_handling=duplicate" \
  --slot "file=build/banks/disk_bank.bin,type=23128,$CS,size_handling=duplicate" \
  --slot "file=build/banks/util_bank.bin,type=23128,$CS,size_handling=duplicate" \
  --slot "file=build/banks/files_bank.bin,type=23128,$CS,size_handling=duplicate" \
  --slot "file=${STOCK_OUT},type=23128,$CS" \
  --out "$OUT"
echo "  c64c fw : $(wc -c < "$OUT" | tr -d ' ') bytes -> $OUT"
echo "  (remember: 'make clean' before a plain breadbin C64 build -- shared build/ tree)"
