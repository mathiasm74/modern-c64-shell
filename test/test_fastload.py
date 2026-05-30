"""Fast-loader Phase 7 bring-up tests.

Phase 7's first piece is the upload mechanism: standard CBM M-W / M-R / M-E
commands on the drive command channel. The fast 2-bit streaming protocol
that runs after the install isn't here yet -- these tests just verify the
plumbing that gets bytes into and out of the drive's RAM.

All tests need a real 1541 on the bus (true drive emulation). Without one,
the no-device timeout fires and the round-trip returns zeros.
"""

import os
import re

VICE_DISK = "data/test.d64"

_LABELS = os.path.join(os.path.dirname(__file__), "..", "build", "labels.txt")


def _label_addr(name):
    """Look up an exported asm label's address from build/labels.txt."""
    with open(_LABELS) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 3 and parts[2].lstrip(".") == name:
                return int(parts[1], 16) & 0xFFFF
    raise AssertionError("label %r not found in %s" % (name, _LABELS))


def _selftest_stub():
    """Six bytes: JSR _fastload_selftest ; JMP self."""
    addr = _label_addr("_fastload_selftest")
    return [
        0x20, addr & 0xFF, (addr >> 8) & 0xFF,    # JSR fastload_selftest
        0x4C, 0x03, 0x10,                          # JMP $1003 (spin)
    ]


def test_fastload_selftest_roundtrips_pattern_through_drive_ram(v):
    """M-W an 8-byte pattern to $0500 in the drive, M-R it back, compare.

    The C-side fastload_selftest() drives the round-trip and stamps its
    result at $0340-$0349 in main RAM (which it owns -- nothing else in the
    shell writes there). We poison the area with $00 first so a hung
    selftest (no $AA marker) is distinguishable from a passed selftest.
    """
    # Poison the result area + put the stub in user RAM.
    v.write_memory(0x0340, [0x00] * 10)
    v.write_memory(0x1000, _selftest_stub())

    # Generous timeout: M-W frame send + UNLISTEN + TALK + M-R reply +
    # UNTALK over slow IEC, with the bit-banged ATN handshake at each step,
    # is comfortably under a second but the drive can take its time to
    # answer.
    v.run_at(0x1000, 3.0)

    marker = v.read_byte(0x0340)
    assert marker == 0xAA, (
        "fastload_selftest did not complete: $0340 = $%02X (expected $AA). "
        "Either the M-W or M-R hung, or the cc65 calling convention is off."
        % marker
    )

    got = v.read_memory(0x0341, 8)
    want = [0xAB, 0xCD, 0xEF, 0x42, 0x55, 0xAA, 0x00, 0xFF]
    assert got == want, (
        "Round-tripped bytes don't match: got %s, want %s. "
        "If got is all zero, no-device timed out (is the disk attached?). "
        "If only some bytes match, the M-W payload was truncated or the "
        "lowercase-fold leaked into the binary body."
        % (["$%02X" % b for b in got], ["$%02X" % b for b in want])
    )

    st = v.read_byte(0x0349)
    # ST_NODEV ($80) is the only bit we'd see; the read path doesn't set EOI
    # for the per-byte loop of an M-R reply. A timeout from the data wait
    # ($02) is also possible if the drive is slow.
    assert (st & 0x80) == 0, (
        "ST after selftest = $%02X; ST_NODEV bit set -- the drive didn't "
        "answer. Confirm -drive8truedrive and that the disk fixture exists."
        % st
    )
