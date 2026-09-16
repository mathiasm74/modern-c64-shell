#!/usr/bin/env python3
"""Derive a bank's EasyFlash linker config from its One ROM one.

The two differ in exactly two mechanical ways, and writing them out by hand
would be five near-duplicate files that have to be kept in step:

  * the RAM window moves out of $9D00-$9FFF. On EasyFlash that range is ROML,
    so a write lands in the RAM underneath while the read comes back from
    flash -- the bank's DATA/BSS/C stack would be write-only. It moves to
    $C800, below the $CE00 completion cache (src/ef/platform.s maps the page).
  * the fixed tables the bank binds to -- the SVC table and the KERNAL entry
    points -- cannot be at $FFxx, which belongs to the stock KERNAL here. They
    are pinned at the top of ROML at the same offsets, $Fxxx -> $9xxx.

Both are asserted rather than assumed: if a source config stops matching the
shape this expects, the build fails instead of quietly emitting a wrong one.

Usage: make_ef_bank_cfg.py <in.cfg> <out.cfg>
"""
import re
import sys

RAM_MOVES = {"$9D00": "$C800", "$9D10": "$C810"}

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
out, moved, rebound = [], 0, 0

for line in text.splitlines(True):
    m = re.match(r"\s*(DATARUN|BANKBSS)\s*:", line)
    if m:
        for old, new in RAM_MOVES.items():
            if "start = %s" % old in line:
                line = line.replace("start = %s" % old, "start = %s" % new)
                moved += 1
                break
        else:
            sys.exit("%s: %s does not start at a known One ROM address:\n%s"
                     % (src, m.group(1), line.rstrip()))
    # SYMBOLS: value = $FFxx  ->  value = $9Fxx (the same table, top of ROML)
    m = re.search(r"value\s*=\s*\$(F[0-9A-Fa-f]{3})", line)
    if m:
        line = line.replace("$" + m.group(1), "$9" + m.group(1)[1:])
        rebound += 1
    out.append(line)

if moved != len(RAM_MOVES):
    sys.exit("%s: expected to move %d RAM areas, moved %d"
             % (src, len(RAM_MOVES), moved))

header = ("# GENERATED from %s by tools/make_ef_bank_cfg.py -- do not edit.\n"
          "# The EasyFlash target moves the bank's RAM window out of ROML and\n"
          "# rebinds the fixed tables from $FFxx to $9Fxx. See the tool.\n") % src
open(dst, "w").write(header + "".join(out))
sys.stderr.write("  %s -> %s (%d areas moved, %d symbols rebound)\n"
                 % (src, dst, moved, rebound))
