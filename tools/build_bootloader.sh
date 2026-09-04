#!/bin/sh
# Build r107sl's C64 bootloader (vendored in third-party/c64-bootloader/) into
# build/c64_bootloader.bin -- loadable ROM set 0 of the onerom-stock firmware,
# the GRUB-style boot menu that selects Tardis DOS / stock / JiffyDOS.
#
# Uses the same from-source cc65 as the shell (ca65/cc65/ld65 on PATH, -t c64,
# c64.lib from CC65_HOME). Upstream sources are used verbatim; see the
# third-party README for provenance and why we build from source (the hosted
# pre-built v0.1.0 binary predates One ROM firmware 0.7.x).
set -e

SRC="third-party/c64-bootloader"
OUT="$1"
[ -n "$OUT" ] || { echo "usage: $0 <output.bin>" >&2; exit 1; }
OBJDIR="$(dirname "$OUT")/bootloader-obj"
mkdir -p "$OBJDIR"

# c64.lib lives under CC65_HOME/lib (the Makefile exports CC65_HOME relative to
# the cc65 binary, exactly as the shell build needs it).
LIB="${CC65_HOME:?CC65_HOME not set (the Makefile sets it)}/lib"

# C -> asm -> obj
cc65 -t c64 -T -O --static-locals -I "$SRC" -o "$OBJDIR/main.s" "$SRC/main.c"
ca65 -t c64 -I "$SRC" -o "$OBJDIR/main.o"    "$OBJDIR/main.s"
ca65 -t c64 -I "$SRC" -o "$OBJDIR/c64boot.o" "$SRC/c64boot.s"
ca65 -t c64 -I "$SRC" -o "$OBJDIR/screen.o"  "$SRC/screen.s"
ca65 -t c64 -I "$SRC" -o "$OBJDIR/rbcp.o"    "$SRC/rbcp.s"

ld65 -o "$OUT" -C "$SRC/rom.cfg" \
     "$OBJDIR/c64boot.o" "$OBJDIR/main.o" "$OBJDIR/screen.o" "$OBJDIR/rbcp.o" \
     -L "$LIB" --lib c64.lib

echo "  c64_bootloader.bin: $(wc -c < "$OUT" | tr -d ' ') bytes (r107sl, from source)"
