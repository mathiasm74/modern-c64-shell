#!/bin/sh
# Regenerate test/data/test.d64, the fixture the disk-I/O tests mount on
# device 8 (see test/test_disk.py). Two files so a directory listing has more
# than just the header:
#   hello  (PRG) - loads at $C000, stores $42 at $CFFF, then loops. Used by the
#                  load/run tests: run JMPs to the load address, so $CFFF==$42
#                  and the PC landing in $C0xx proves it executed.
#   readme (PRG) - a short payload, just a second directory entry.
#
# Requires c1541 (ships with VICE). Run from anywhere; writes next to itself.
set -e
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" <<'PY'
import sys, os
tmp = sys.argv[1]
hello = bytes([0x00, 0xC0,        # load address $C000
               0xA9, 0x42,        # LDA #$42
               0x8D, 0xFF, 0xCF,  # STA $CFFF
               0x4C, 0x05, 0xC0]) # JMP $C005 (loop forever)
open(os.path.join(tmp, "hello.prg"), "wb").write(hello)
open(os.path.join(tmp, "readme.prg"), "wb").write(
    bytes([0x00, 0x20]) + b"C64 SHELL TEST DISK")
PY

c1541 -format "test disk,01" d64 "$here/test.d64" \
      -write "$tmp/hello.prg"  "hello,p" \
      -write "$tmp/readme.prg" "readme,p"
echo "wrote $here/test.d64"
