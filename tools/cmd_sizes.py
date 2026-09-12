#!/usr/bin/env python3
"""Report the ROM code size of each shell command and its helpers.

Assembles the command modules (build/commands/*.s, produced by `make`) with a
ca65 listing, measures each function from its `.proc` marker to the next, and
walks the jsr/jmp call graph (per module, so two static helpers that share a C
name -- e.g. mem.c and fs.c both have parse_num -- stay distinct) to split each
command's cost into:

  - exclusive : the command body + the helpers only that command reaches
  - shared    : helpers reached by two or more commands (reported once)

Calls that leave the command modules (the IEC / screen / RBCP layers, the
KERNAL stubs, the overlay loader) are resident infrastructure and aren't
attributed to any command. RODATA (usage strings etc.) is not counted -- it's
a handful of bytes per command on top.

Commands whose body lives in a tardis overlay show as kind=overlay; the size
then is just the resident thunk.

Most commands are BANK commands now (docs/ROM-EXPANSION.md): their dispatch row
names a bank entry instead of a resident function, so they have no resident
code whatsoever. They are listed separately at the end with what they actually
cost the 16KB ROM -- the 4-byte table row plus the name string -- because "0
bytes of code" is the point of that architecture, and a report that silently
omitted them would overstate what is left to move.

Run `make` first so the .s files exist.
Usage: tools/cmd_sizes.py [build-dir]   (default: build)
"""
import os
import re
import subprocess
import sys

BUILD = sys.argv[1] if len(sys.argv) > 1 else "build"
# The command modules that still exist. mem.c and config.c are gone: peek/
# poke and the colour commands moved into the files BANK, leaving no
# resident code at all (see the bank listing at the end of the report).
# overlay.c is gone with the last RAM overlay: every command lives in a bank,
# so there is no fetch machinery left to measure.
MODULES = ["builtins", "fs"]

# Commands whose real body is in an overlay (resident side is only a thunk).
OVERLAY_CMDS = {"cat", "less", "cp", "mv", "rm", "save", "status", "cd",
                "dir", "ls", "pwd", "border", "bg", "text", "prompt",
                "about", "edit"}

CODE_SEGS = ("CODE", "CODE2")


def assemble_listing(mod):
    src = os.path.join(BUILD, "commands", mod + ".s")
    if not os.path.exists(src):
        sys.exit("missing %s -- run `make` first" % src)
    lst = "/tmp/cmdsize_%s.lst" % mod
    subprocess.run(["ca65", "--cpu", "6502", "-l", lst,
                    "-o", "/tmp/cmdsize_%s.o" % mod, src],
                   check=True, capture_output=True)
    return lst


# Nodes are keyed by (module, name) so same-named statics stay separate.
size = {}            # (mod, name) -> bytes
calls = {}           # (mod, name) -> set((mod, callee))

for mod in MODULES:
    lines = list(open(assemble_listing(mod), errors="ignore"))

    # Pass 1: function extents. ca65 lists "<6 hex addr>r <depth> <bytes> src";
    # the address is the running offset within the current segment, and cc65
    # wraps each function in `.proc _name`. Size = gap to the next proc in the
    # same segment (or to the segment end for the last one).
    seg = None
    procs = {}                       # seg -> [(addr, name)]
    seg_end = {}
    for line in lines:
        sm = re.search(r'\.segment\s+"([^"]+)"', line)
        if sm:
            seg = sm.group(1)
        m = re.match(r'^([0-9A-Fa-f]{6})r?\s', line)
        if not m or sm:
            continue
        addr = int(m.group(1), 16)
        seg_end[seg] = max(seg_end.get(seg, 0), addr)
        pm = re.search(r'\.proc\s+(_\w+)', line)
        if pm:
            procs.setdefault(seg, []).append((addr, pm.group(1)[1:]))
    for seg, ps in procs.items():
        if seg not in CODE_SEGS:
            continue
        for i, (addr, name) in enumerate(ps):
            nxt = ps[i + 1][0] if i + 1 < len(ps) else seg_end[seg]
            size[(mod, name)] = size.get((mod, name), 0) + (nxt - addr)

    # Pass 2: call edges. A `jsr/jmp _X` inside module mod resolves to that
    # module's own _X if it defines one (statics are module-local); otherwise
    # it's an external symbol (another module / asm) and isn't attributed.
    cur = None
    for line in lines:
        pm = re.search(r'\.proc\s+(_\w+)', line)
        if pm:
            cur = pm.group(1)[1:]
            continue
        if re.search(r'\.endproc', line):
            cur = None
            continue
        cm = re.search(r'\b(?:jsr|jmp)\s+_(\w+)\b', line)
        if cm and cur and (mod, cm.group(1)) in size:
            calls.setdefault((mod, cur), set()).add((mod, cm.group(1)))

nodes = set(size)
commands = sorted(n for n in nodes if n[1].startswith("cmd_"))
# Bank-dispatch plumbing serves EVERY bank command, but the only resident
# command that reaches it is `run` -- so the call-graph walk would charge all of
# it to `run` and overstate it several-fold. Treat it as infrastructure, like
# the IEC/screen layers, and report it separately.
INFRA = {"bank_try", "bank_dispatch", "report_no_bank"}

helpers = [n for n in nodes if not n[1].startswith("cmd_") and n[1] not in INFRA]
infra = [n for n in nodes if n[1] in INFRA]


def reachable(start):
    seen, stack = set(), [start]
    while stack:
        for callee in calls.get(stack.pop(), ()):
            if callee not in seen:
                seen.add(callee)
                stack.append(callee)
    return seen


cmd_reach = {c: reachable(c) for c in commands}
reachers = {h: set() for h in helpers}            # helper -> commands reaching it
for c in commands:
    for h in cmd_reach[c]:
        if h in reachers:
            reachers[h].add(c)


def disp(node):
    """Bare name unless it collides across modules, then 'mod:name'."""
    same = [m for (m, n) in nodes if n == node[1]]
    return node[1] if len(same) == 1 else "%s:%s" % node


def exclusive_total(c):
    total = size[c]
    for h in cmd_reach[c]:
        if reachers.get(h) == {c}:
            total += size[h]
    return total


print("== shell command code sizes "
      "(CODE/CODE2 bytes; RODATA strings extra) ==\n")
print("%-9s %6s  %-8s  %s" % ("command", "total", "kind", "exclusive helpers"))
rows = []
for c in commands:
    excl = [h for h in cmd_reach[c] if reachers.get(h) == {c}]
    kind = "overlay" if c[1][4:] in OVERLAY_CMDS else "resident"
    rows.append((exclusive_total(c), c, kind,
                 sorted(excl, key=lambda h: -size[h])))
for total, c, kind, excl in sorted(rows, key=lambda r: -r[0]):
    helped = " ".join("%s(%d)" % (disp(h), size[h]) for h in excl)
    print("%-9s %6d  %-8s  %s" % (c[1][4:], total, kind, helped))

resident_total = sum(t for t, c, k, _ in rows if k == "resident")
print("\nresident-command code (exclusive, incl. private helpers): %d bytes"
      % resident_total)

shared = [(size[h], h, sorted(reachers[h])) for h in helpers
          if len(reachers.get(h, ())) > 1]
if shared:
    print("\n== shared helpers (reached by 2+ commands; counted once) ==")
    for b, h, cs in sorted(shared, reverse=True):
        print("  %-22s %5d  <- %s" % (disp(h), b, ", ".join(c[1][4:] for c in cs)))

if infra:
    print("\n== bank-dispatch plumbing (serves every bank command) ==")
    for b, h in sorted(((size[n], n) for n in infra), reverse=True):
        print("  %-22s %5d" % (disp(h), b))
    print("  %-22s %5d  total" % ("", sum(size[n] for n in infra)))

orphan = [(size[h], h) for h in helpers if not reachers.get(h)]
if orphan:
    print("\n== helpers not reached from any command "
          "(asm-/indirect-called) ==")
    for b, h in sorted(orphan, reverse=True):
        print("  %-22s %5d" % (disp(h), b))

# Overlay bodies live in their own flash sets OUTSIDE the 16K ROM, so they're
# absent from the resident totals above (e.g. the color picker is an overlay
# command with only a thin resident thunk). List each packed .bin so the code
# that moved out of ROM is still accounted for somewhere.
ovl_dir = os.path.join(BUILD, "overlays")
if os.path.isdir(ovl_dir):
    bins = sorted(f for f in os.listdir(ovl_dir) if f.endswith(".bin"))
    if bins:
        print("\n== overlay bodies (outside the 16K ROM; packed .bin sizes) ==")
        for f in bins:
            n = os.path.getsize(os.path.join(ovl_dir, f))
            print("  %-22s %5d  (%d pages)" % (f, n, (n + 255) // 256))


# --- bank commands ----------------------------------------------------------
# A BANK_CMD row names a bank entry rather than a resident function, so these
# commands contribute NO code to the 16KB ROM -- only their dispatch row (4
# bytes) and their name string. Read them straight out of the table in shell.c
# so the list cannot drift from what actually dispatches.
shell_c = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "src", "shell.c")
try:
    src = open(shell_c).read()
except OSError:
    src = ""
bank_rows = re.findall(r'\{\s*"([^"]+)"\s*,\s*BANK_CMD\(\s*(\w+)\s*,\s*(\d+)\s*\)',
                       src)
if bank_rows:
    print("\n== bank commands (no resident code; row + name only) ==")
    per = []
    for name, bank, entry in sorted(bank_rows):
        cost = 4 + len(name) + 1        # table row + NUL-terminated name
        per.append(cost)
        print("  %-9s %5d  %s entry %s" % (name, cost, bank.replace("BANK_", "").lower(),
                                           entry))
    print("  %-9s %5d  total" % ("", sum(per)))

# --- how full each bank is --------------------------------------------------
# The .bin is always 8192 (it is $FF-padded to fill the served window), so the
# file size says nothing. Read the link map instead.
#
# Two budgets matter, and they are not the same:
#   ROM  -- the $A000-$BFFF window, 8KB, private to each bank.
#   RAM  -- DATA+BSS+C stack, which every bank SHARES ($9D00-$9FFF) and which
#           is carved out of the program load area. So the ROM column is per
#           bank, but the RAM column is a claim on one common budget: the
#           largest bank sets the floor, and with it the biggest program the
#           machine can load.
BANK_WINDOW = 0x2000                    # $A000-$BFFF
BANK_RAM_TOP = 0xA000                   # the C stack grows down from here
ROM_SEGS = ("ENTRY", "CODE", "RODATA", "CODE2", "RODATA2", "DATA")
RAM_SEGS = ("BSS",)

def read_map(path):
    """Segment name -> (start, size) from an ld65 map file."""
    segs = {}
    inlist = False
    for line in open(path, errors="ignore"):
        if line.startswith("Segment list:"):
            inlist = True
            continue
        if inlist:
            if line.startswith("Exports list:") or line.startswith("Modules list:"):
                break
            m = re.match(r"^(\w+)\s+([0-9A-Fa-f]{6})\s+([0-9A-Fa-f]{6})\s+([0-9A-Fa-f]{6})", line)
            if m:
                segs[m.group(1)] = (int(m.group(2), 16), int(m.group(4), 16))
    return segs

bank_dir = os.path.join(BUILD, "banks")
maps = sorted(f for f in os.listdir(bank_dir) if f.endswith(".map")) \
       if os.path.isdir(bank_dir) else []
if maps:
    print("\n== bank fullness (each served into the same 8KB $A000 window) ==")
    print("  %-12s %11s %6s   %s" % ("bank", "ROM used", "free", "bar"))
    ram_hi = 0
    for f in maps:
        segs = read_map(os.path.join(bank_dir, f))
        rom = sum(sz for n, (_st, sz) in segs.items() if n in ROM_SEGS)
        free = BANK_WINDOW - rom
        pct = rom * 100 // BANK_WINDOW
        bar = "#" * (pct * 24 // 100)
        print("  %-12s %5d/%4d %6d   %-24s %d%%"
              % (f[:-4], rom, BANK_WINDOW, free, bar, pct))
        for n in RAM_SEGS:
            if n in segs:
                st, sz = segs[n]
                ram_hi = max(ram_hi, st + sz)
    if ram_hi:
        print("\n  shared bank RAM: BSS reaches $%04X; the C stack grows down from"
              " $%04X" % (ram_hi, BANK_RAM_TOP))
        print("  (one common budget -- it is carved out of the program load area,"
              " so the\n   largest bank sets the load ceiling for every program)")
