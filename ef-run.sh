#!/usr/bin/env bash
#
# ef-run.sh - Build the EasyFlash cartridge and launch VICE (x64sc) with it.
#
# The counterpart to run.sh, which boots the One ROM build by replacing the
# machine's ROMs. Here the machine keeps its STOCK KERNAL and BASIC and Tardis
# arrives as a cartridge -- which is the whole point of the target, and why
# stock-roms/ is required rather than optional.
#
# Usage:
#   ./ef-run.sh [extra x64sc args...]
#   DISK=test/data/test.d64 ./ef-run.sh    # ...with a disk on device 8
#   SKIP_BUILD=1 ./ef-run.sh               # launch the existing build
#
# Note VICE's `+easyflashjumper` is the setting that BOOTS the cartridge -- the
# sense is the inverse of what the spec's wording suggests.
#
# It REPLACES a running instance of itself, because that is the edit-build-look
# loop. A hard reset inside VICE will not do: it re-runs the cartridge from the
# image VICE already holds in memory, so a rebuilt .crt is not picked up. (The
# in-GUI equivalent is Cartridge -> Attach CRT image, pick the file again, then
# a hard reset.) Set KEEP=1 to leave an existing window alone and open another.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

CRT="$ROOT/build/ef/tardis.crt"
STOCK_K="$ROOT/stock-roms/kernal.901227-03.bin"
STOCK_B="$ROOT/stock-roms/basic.901226-01.bin"
VICE="${VICE:-x64sc}"

if ! command -v "$VICE" >/dev/null 2>&1; then
    echo "error: '$VICE' not found on PATH (install VICE, or set VICE=/path/to/x64sc)" >&2
    exit 1
fi
for rom in "$STOCK_K" "$STOCK_B"; do
    if [[ ! -f "$rom" ]]; then
        echo "error: $rom not found -- the EF target runs on a stock machine," >&2
        echo "       so stock-roms/ must be populated (gitignored, user-supplied)." >&2
        exit 1
    fi
done

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    make ef
fi

if [[ "${KEEP:-0}" != "1" ]] && pgrep -f "x64sc.*$(basename "$CRT")" >/dev/null 2>&1; then
    echo "replacing the running instance (KEEP=1 to keep it)"
    pkill -f "x64sc.*$(basename "$CRT")" || true
    # Give the old process a moment to release the window and the disk image.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "x64sc.*$(basename "$CRT")" >/dev/null 2>&1 || break
        sleep 0.2
    done
fi

echo "launching $VICE with the EasyFlash cartridge:"
echo "  -cartcrt $CRT"
echo "  stock KERNAL + BASIC (the cartridge supplies Tardis)"

ARGS=(-kernal "$STOCK_K" -basic "$STOCK_B" -cartcrt "$CRT" +easyflashjumper)
if [[ -n "${DISK:-}" ]]; then
    if [[ ! -f "$DISK" ]]; then
        echo "error: disk image '$DISK' not found" >&2
        exit 1
    fi
    # A fresh writable copy, so a session's cp/rm never touch the tracked image.
    SCRATCH="$ROOT/build/ef-run-disk.d64"
    cp "$DISK" "$SCRATCH"
    ARGS+=(-drive8truedrive -8 "$SCRATCH")
    echo "  -8       $SCRATCH (writable copy of $DISK; original untouched)"
fi
exec "$VICE" "${ARGS[@]}" "$@"
