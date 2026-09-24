#!/usr/bin/env python3
"""Patch the boot screen's "rom free" line with the real free bytes per ROM half.

Free space is a build-time value, and it can't be had from a simple linker
symbol: the KERNAL half is fragmented by fixed-address stubs, and segments like
RBCP_CODE / DATA *load* into the KERNAL ROM but *run* in RAM, so the map's run
addresses understate it. So we sum each segment's size (from the linker map)
against its LOAD area (from cfg/rom.cfg), then write the two numbers into the
"----" placeholder fields of the `freemem` string in kernal.bin (located via
build/labels.txt). The string keeps its length, so the binary size is unchanged.

Usage: patch_freemem.py <build-dir>          # the One ROM build
       patch_freemem.py <build-dir> --ef     # the EasyFlash build
"""
import os
import re
import sys

build = sys.argv[1]
ef = "--ef" in sys.argv[2:]

# Per-target: the linker config, the map/labels the link produced, the two ROM
# areas the banner reports, and where the patched string physically lives.
if ef:
    CFG, MAP, LABELS = "cfg/ef_rom.cfg", "ef/tardis.map", "ef/tardis.labels"
    AREAS = ("ROMH0", "ROML")   # filled in the banner's order: BASIC, KERNAL
    LABEL, BIN, BASE = "ef_freemem", "ef/tardis-roml.bin", 0x8000
else:
    CFG, MAP, LABELS = "cfg/rom.cfg", "rom.map", "labels.txt"
    AREAS = ("BASIC", "KERNAL")
    LABEL, BIN, BASE = "freemem", "kernal.bin", 0xE000
CAP = 8192

# segment -> load area, from the linker config
seg_area = {}
for line in open(CFG):
    m = re.match(r"\s*([A-Z_0-9]+):.*\bload\s*=\s*(%s)\b" % "|".join(AREAS), line)
    if m:
        seg_area[m.group(1)] = m.group(2)

# segment -> size, from the map's segment list
size = {}
for line in open(os.path.join(build, MAP)):
    m = re.match(r"^([A-Z_0-9]+)\s+[0-9A-Fa-f]{6}\s+[0-9A-Fa-f]{6}\s+([0-9A-Fa-f]{6})",
                 line)
    if m:
        size[m.group(1)] = int(m.group(2), 16)

used = dict.fromkeys(AREAS, 0)
for seg, area in seg_area.items():
    used[area] += size.get(seg, 0)
free = {a: CAP - used[a] for a in AREAS}

# locate the freemem string
addr = None
for line in open(os.path.join(build, LABELS)):
    p = line.split()
    if len(p) >= 3 and p[0] == "al" and p[2].lstrip(".") == LABEL:
        addr = int(p[1], 16) & 0xFFFF
if addr is None:
    sys.exit("patch_freemem: '%s' label not found" % LABEL)

path = os.path.join(build, BIN)
data = bytearray(open(path, "rb").read())
off = addr - BASE
text = bytes(data[off:data.index(0, off)]).decode("latin1")
if text.count("----") != 2:
    sys.exit("patch_freemem: %s needs exactly two '----' fields" % LABEL)
for a in AREAS:
    text = text.replace("----", "%4d" % free[a], 1)
data[off:off + len(text)] = text.encode("latin1")
open(path, "wb").write(data)
sys.stderr.write("  rom free: %s\n" % ", ".join(
    "%s %d" % (a.lower(), free[a]) for a in AREAS))
