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
then is just the resident thunk (which for `save`/`cd` still does real
arg-building, hence they're bigger than the other thunks).

Run `make` first so the .s files exist.
Usage: tools/cmd_sizes.py [build-dir]   (default: build)
"""
import os
import re
import subprocess
import sys

BUILD = sys.argv[1] if len(sys.argv) > 1 else "build"
MODULES = ["builtins", "mem", "fs", "config"]

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
helpers = [n for n in nodes if not n[1].startswith("cmd_")]


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
