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
#   doc    (SEQ) - 30 lines "l00".."l29"; long enough that `less` pages it
#                  and `cat` scrolls.
#   bas    (PRG) - a real tokenized BASIC V2 program (loads at $0801). The
#                  editor detokenizes it for display, so it needs to be
#                  genuinely tokenized. It carries the three cases that catch
#                  a wrong tokenizer: a keyword inside a STRING, a keyword's
#                  letters inside a REM ("DONE" contains ON), and the same
#                  inside DATA ("ONE"). BASIC stops tokenizing after REM (to
#                  end of line) and after DATA (to the next colon), so all
#                  three must survive as plain text.
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
doc = "".join("l%02d\r" % i for i in range(30))   # 30 lines, CR-separated
open(os.path.join(tmp, "doc.seq"), "wb").write(doc.encode("ascii"))

# A genuine tokenized BASIC V2 program:
#   10 PRINT "HI PRINT"        <- the keyword inside the quotes stays literal
#   20 REM DONE
# Lines are: link(2) line#(2) tokens... $00, ending with a $0000 link.
def basic(lines, start=0x0801):
    out, addr = b"", start
    body = []
    for num, toks in lines:
        chunk = bytes([num & 0xFF, num >> 8]) + toks + b"\x00"
        body.append(chunk)
    for chunk in body:
        addr += 2 + len(chunk) - 2          # link + line#/tokens/terminator
    addr = start
    for chunk in body:
        nxt = addr + 2 + len(chunk)
        out += bytes([nxt & 0xFF, nxt >> 8]) + chunk
        addr = nxt
    return bytes([start & 0xFF, start >> 8]) + out + b"\x00\x00"

PRINT, REM = b"\x99", b"\x8f"
DATA = b"\x83"
open(os.path.join(tmp, "bas.prg"), "wb").write(
    basic([(10, PRINT + b' "HI PRINT"'),
           (20, DATA + b" ONE,TWO"),
           (30, REM + b" DONE")]))
PY

c1541 -format "test disk,01" d64 "$here/test.d64" \
      -write "$tmp/prog.prg"  "prog,p" \
      -write "$tmp/readme.prg" "readme,p" \
      -write "$tmp/doc.seq"   "doc,s" \
      -write "$tmp/bas.prg"   "bas,p"
echo "wrote $here/test.d64"
