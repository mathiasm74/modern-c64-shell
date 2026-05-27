#!/bin/sh
# Regenerate test/data/test.d64, the fixture the disk-I/O tests mount on
# device 8 (see test/test_disk.py). Two files so a directory listing has more
# than just the header:
#   prog   (PRG) - loads at $2000; prints "hello from prog" via CHROUT ($FFD2)
#                  and RTSes. Used by the load/run tests: run calls it like SYS,
#                  so the message proves it executed and the shell regaining the
#                  prompt proves the RTS returned. ($2000 is clear of the
#                  shell's working RAM at $C000-$CFFF, which a load there would
#                  corrupt.)
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
# Print a NUL-terminated message at $200E through CHROUT, then RTS:
#   2000  LDX #$00
#   2002  LDA $200E,X     ; the message
#   2005  BEQ $200D       ; NUL -> done
#   2007  JSR $FFD2       ; CHROUT
#   200A  INX
#   200B  BNE $2002
#   200D  RTS
prog = bytes([0x00, 0x20,                 # load address $2000
              0xA2, 0x00,                 # LDX #$00
              0xBD, 0x0E, 0x20,           # LDA $200E,X
              0xF0, 0x06,                 # BEQ $200D
              0x20, 0xD2, 0xFF,           # JSR $FFD2
              0xE8,                       # INX
              0xD0, 0xF5,                 # BNE $2002
              0x60])                      # RTS
prog += b"hello from prog" + bytes([0x0D, 0x00])
open(os.path.join(tmp, "prog.prg"), "wb").write(prog)
open(os.path.join(tmp, "readme.prg"), "wb").write(
    bytes([0x00, 0x20]) + b"C64 SHELL TEST DISK")
PY

c1541 -format "test disk,01" d64 "$here/test.d64" \
      -write "$tmp/prog.prg"  "prog,p" \
      -write "$tmp/readme.prg" "readme,p"
echo "wrote $here/test.d64"
