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


def _jsr_then_spin(symbol):
    """Six-byte ML stub: JSR <symbol> ; JMP self."""
    addr = _label_addr(symbol)
    return [
        0x20, addr & 0xFF, (addr >> 8) & 0xFF,    # JSR <addr>
        0x4C, 0x03, 0x10,                          # JMP $1003 (spin)
    ]


def test_epyx_upload_matches_meatloaf_v2v3_signature(v):
    """Step 1: the drive-side Epyx handshake. Meatloaf recognises the cartridge
    by three 25-byte M-W chunks whose 8-bit additive checksums are $53/$A6/$8F
    (IECFileDevice.cpp epyxV2V3sig), then M-E $01A9. It only sums the bytes, so
    our upload is clean-room filler -- but the sums must be exact. Read the 75
    bytes out of ROM and check each chunk. (The actual Epyx-mode handoff only
    happens on a real Meatloaf; VICE's 1541 can't model it, so this verifies
    the one thing that must be byte-exact.)"""
    base = _label_addr("_fastload_epyx_upload")
    data = v.read_memory(base, 3 * 0x19)
    want = [0x53, 0xA6, 0x8F]
    for k, expect in enumerate(want):
        chunk = data[k * 0x19:(k + 1) * 0x19]
        assert len(chunk) == 0x19
        got = sum(chunk) & 0xFF
        assert got == expect, \
            "Epyx chunk %d ($%04X) sum = $%02X, expected $%02X" \
            % (k + 1, [0x0180, 0x0199, 0x01B2][k], got, expect)
