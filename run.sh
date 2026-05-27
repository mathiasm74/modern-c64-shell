#!/usr/bin/env bash
#
# run.sh - Build the C64 shell ROM and launch VICE (x64sc) with it installed.
#
# Usage:
#   ./run.sh [extra x64sc args...]
#
# Examples:
#   ./run.sh                  # build, then boot the shell ROM in VICE
#   ./run.sh -warp            # ...with warp mode enabled
#   DISK=test/data/test.d64 ./run.sh   # ...with a disk on device 8 (for ls/load)
#   SKIP_BUILD=1 ./run.sh     # launch the existing build without rebuilding
#   VICE=/path/to/x64sc ./run.sh
#
# Disk commands (ls/load) need a real image attached AND true drive emulation
# (we replaced the KERNAL, so VICE's virtual-device traps never fire). Set
# DISK= to attach one; without it, typing `ls` talks to an empty drive that
# blinks but never returns a directory, hanging the shell.
#
set -euo pipefail

# Work from the repo root (this script's directory) so it runs from anywhere.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

KERNAL="$ROOT/build/kernal.bin"
BASIC="$ROOT/build/basic.bin"
VICE="${VICE:-x64sc}"

if ! command -v "$VICE" >/dev/null 2>&1; then
    echo "error: '$VICE' not found on PATH (install VICE, or set VICE=/path/to/x64sc)" >&2
    exit 1
fi

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    make all
fi

if [[ ! -f "$KERNAL" || ! -f "$BASIC" ]]; then
    echo "error: ROM binaries not found; run 'make' first (or unset SKIP_BUILD)" >&2
    exit 1
fi

echo "launching $VICE with the shell ROM:"
echo "  -kernal $KERNAL"
echo "  -basic  $BASIC"

ARGS=(-kernal "$KERNAL" -basic "$BASIC")
if [[ -n "${DISK:-}" ]]; then
    if [[ ! -f "$DISK" ]]; then
        echo "error: disk image '$DISK' not found" >&2
        exit 1
    fi
    # True drive emulation is required for the ROM's IEC routines to work.
    ARGS+=(-drive8truedrive -8 "$DISK")
    echo "  -8      $DISK (device 8, true drive)"
fi
exec "$VICE" "${ARGS[@]}" "$@"
