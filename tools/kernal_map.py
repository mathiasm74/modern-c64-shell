#!/usr/bin/env python3
"""Which bytes of the stock C64 KERNAL are reachable ONLY from the tape paths?

Answers the question the Epyx-into-tape-space plan rests on: the shell declares
tape a non-goal, so tape-only ROM is space we can patch a fast loader into -- but
only if nothing else can reach it. Run it to re-verify against a different KERNAL
revision, or after changing what counts as a tape root.

    python3 tools/kernal_map.py [stock-roms/kernal.901227-03.bin]

Method, and its limits:

  * Roots are every documented way IN: the $FF81-$FFF5 jump table, the sixteen
    RAM-vector defaults RESTOR copies from $FD30, and the NMI/RESET/IRQ vectors.
  * Tape roots are the device-1/2 branches of LOAD and SAVE (found by reading
    the `lda $BA / cmp #$03 / bcc` dispatch, not from a memory of KERNAL maps),
    PLUS the three IRQ handlers tape installs into $0314 from its own table at
    $FD9B -- no static trace can follow a handler installed through a vector, and
    without them 684 bytes of tape code look merely unreachable.
  * Control flow only. So it also checks, separately, that no instruction outside
    the candidate ranges REFERENCES an address inside them -- a data table living
    in the middle of tape code would not show up any other way.
  * Decode operand bytes as opcodes and you invent references that are not there
    (an early version of this reported seven). Everything here walks instruction
    START addresses, never the covered-byte set.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m6502dis as dis

TAPE_ROOTS = {
    0xF533: "tape LOAD  (ILOAD's device 1-2 branch, $F4B6 bcc)",
    0xF659: "tape SAVE  (ISAVE's device 1-2 branch, $F5F8 bcc)",
    0xFC6A: "tape IRQ handler (installed via the $FD9B table)",
    0xFBCD: "tape IRQ handler (installed via the $FD9B table)",
    0xF92C: "tape IRQ handler (installed via the $FD9B table)",
}


def trace(rom, roots, stop_at=frozenset()):
    """-> (instruction starts, covered bytes). Starts are what may be decoded."""
    starts, covered, work = set(), set(), list(roots)
    while work:
        pc = work.pop()
        while True:
            if pc not in rom or pc in starts or pc in stop_at:
                break
            d = rom.decode(pc)
            if d is None:
                break
            mn, mode, size, val = d
            starts.add(pc)
            covered.update(range(pc, pc + size))
            if mn == "JSR":
                if val in rom:
                    work.append(val)
                pc += size
                continue
            if mn in ("BPL", "BMI", "BVC", "BVS", "BCC", "BCS", "BNE", "BEQ"):
                work.append(val)
                pc += size
                continue
            if mn == "JMP":
                if mode == "abs" and val in rom:
                    work.append(val)
                break
            if mn in ("RTS", "RTI", "BRK"):
                break
            pc += size
    return starts, covered


def runs(s, lo, hi, minlen=16):
    out, cur = [], None
    for a in range(lo, hi + 2):
        if a in s:
            if cur is None:
                cur = a
        elif cur is not None:
            if a - cur >= minlen:
                out.append((cur, a - 1))
            cur = None
    return out


def main(path):
    rom = dis.Rom(open(path, "rb").read(), 0xE000)

    roots = set()
    for a in range(0xFF81, 0xFFF6, 3):
        d = rom.decode(a)
        if d and d[0] == "JMP" and d[1] == "abs":
            roots.add(d[3])
    for i in range(16):
        roots.add(rom.w(0xFD30 + i * 2))
    for v in (0xFFFA, 0xFFFC, 0xFFFE):
        roots.add(rom.w(v))

    nt_starts, nt_cov = trace(rom, roots, stop_at=set(TAPE_ROOTS))
    tp_starts, tp_cov = trace(rom, set(TAPE_ROOTS))
    only_tape = tp_cov - nt_cov

    print("%s" % os.path.basename(path))
    print("  reachable from documented entries : %5d bytes" % len(nt_cov))
    print("  reachable ONLY via tape           : %5d bytes" % len(only_tape))
    print()
    print("TAPE-ONLY RUNS (candidates to overwrite):")
    cand = runs(only_tape, 0xE000, 0xFFFF)
    total = 0
    for a, b in cand:
        print("  $%04X-$%04X  %5d bytes" % (a, b, b - a + 1))
        total += b - a + 1
    print("  %d bytes total, largest contiguous %d" %
          (total, max(b - a + 1 for a, b in cand)))

    def in_cand(a):
        return any(lo <= a <= hi for lo, hi in cand)

    print()
    print("SAFETY: references INTO those ranges from code outside them")
    bad = 0
    for a in sorted(nt_starts | tp_starts):
        if in_cand(a):
            continue
        d = rom.decode(a)
        if not d:
            continue
        mn, mode, size, val = d
        if mode in ("abs", "abx", "aby", "ind") and val is not None and in_cand(val):
            who = "tape" if a in tp_starts else "NON-TAPE"
            print("  $%04X (%s) %s $%04X" % (a, who, mn, val))
            if who == "NON-TAPE":
                bad += 1
    print("  %d from non-tape code%s" % (bad, "  <-- NOT SAFE" if bad else "  (clear)"))

    print()
    print("SAFETY: indirect jumps, which control-flow tracing cannot follow")
    defaults = {0x314 + i * 2: rom.w(0xFD30 + i * 2) for i in range(16)}
    for a in sorted(nt_starts | tp_starts):
        d = rom.decode(a)
        if d and d[0] == "JMP" and d[1] == "ind":
            t = defaults.get(d[3])
            flag = "  <-- INTO A CANDIDATE" if t and in_cand(t) else ""
            print("  $%04X  JMP ($%04X)  default $%s%s"
                  % (a, d[3], ("%04X" % t) if t else "????", flag))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "stock-roms/kernal.901227-03.bin")
