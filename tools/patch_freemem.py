#!/usr/bin/env python3
"""Patch the boot screen's "rom free" line with the real free bytes per ROM half.

Free space is a build-time value, and it can't be had from a simple linker
symbol: the KERNAL half is fragmented by fixed-address stubs, and segments like
RBCP_CODE / DATA *load* into the KERNAL ROM but *run* in RAM, so the map's run
addresses understate it. So we sum each segment's size (from the linker map)
against its LOAD area (from cfg/rom.cfg), then write the two numbers into the
"----" placeholder fields of the `freemem` string in kernal.bin (located via
build/labels.txt). The string keeps its length, so the binary size is unchanged.

Usage: patch_freemem.py <build-dir>
"""
import os
import re
import sys

build = sys.argv[1]
CAP = 8192

# segment -> load area, from the linker config
seg_area = {}
for line in open("cfg/rom.cfg"):
    m = re.match(r"\s*([A-Z_0-9]+):.*\bload\s*=\s*(BASIC|KERNAL)\b", line)
    if m:
        seg_area[m.group(1)] = m.group(2)

# segment -> size, from the map's segment list
size = {}
for line in open(os.path.join(build, "rom.map")):
    m = re.match(r"^([A-Z_0-9]+)\s+[0-9A-Fa-f]{6}\s+[0-9A-Fa-f]{6}\s+([0-9A-Fa-f]{6})",
                 line)
    if m:
        size[m.group(1)] = int(m.group(2), 16)

used = {"BASIC": 0, "KERNAL": 0}
for seg, area in seg_area.items():
    used[area] += size.get(seg, 0)
free = {"BASIC": CAP - used["BASIC"], "KERNAL": CAP - used["KERNAL"]}

# locate `freemem` in kernal.bin
addr = None
for line in open(os.path.join(build, "labels.txt")):
    p = line.split()
    if len(p) >= 3 and p[0] == "al" and p[2].lstrip(".") == "freemem":
        addr = int(p[1], 16) & 0xFFFF
if addr is None:
    sys.exit("patch_freemem: 'freemem' label not found (export it in reset.s)")

path = os.path.join(build, "kernal.bin")
data = bytearray(open(path, "rb").read())
off = addr - 0xE000
text = bytes(data[off:data.index(0, off)]).decode("latin1")
if text.count("----") != 2:
    sys.exit("patch_freemem: freemem needs exactly two '----' fields")
text = text.replace("----", "%4d" % free["BASIC"], 1)
text = text.replace("----", "%4d" % free["KERNAL"], 1)
data[off:off + len(text)] = text.encode("latin1")
open(path, "wb").write(data)
sys.stderr.write("  rom free: basic %d, kernal %d\n" % (free["BASIC"], free["KERNAL"]))
