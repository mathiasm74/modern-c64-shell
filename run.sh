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
#   SKIP_BUILD=1 ./run.sh     # launch the existing build without rebuilding
#   VICE=/path/to/x64sc ./run.sh
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
exec "$VICE" -kernal "$KERNAL" -basic "$BASIC" "$@"
