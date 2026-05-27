#!/bin/sh
# Regenerate test/data/test.d64, the fixture the disk-I/O tests mount on
# device 8 (see test/test_disk.py). Two files so a directory listing has more
# than just the header:
#   prog   (PRG) - loads at $2000, stores $42 at $0340 (the free cassette
#                  buffer), then loops. Used by the load/run tests: run JMPs to
#                  the load address, so $0340==$42 and the PC landing in $20xx
#                  proves it executed. ($2000 is clear of the shell's working
#                  RAM at $C000-$CFFF, which a load there would corrupt.)
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
prog = bytes([0x00, 0x20,         # load address $2000
              0xA9, 0x42,         # LDA #$42
              0x8D, 0x40, 0x03,   # STA $0340
              0x4C, 0x05, 0x20])  # JMP $2005 (loop forever)
open(os.path.join(tmp, "prog.prg"), "wb").write(prog)
open(os.path.join(tmp, "readme.prg"), "wb").write(
    bytes([0x00, 0x20]) + b"C64 SHELL TEST DISK")
PY

c1541 -format "test disk,01" d64 "$here/test.d64" \
      -write "$tmp/prog.prg"  "prog,p" \
      -write "$tmp/readme.prg" "readme,p"
echo "wrote $here/test.d64"
