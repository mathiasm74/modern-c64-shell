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


# --- Epyx receiver descramble table ---------------------------------------
# The fast receiver (_epyx_recv_byte) folds a byte's four $DD00 samples into one
# scrambled value AS it samples (lsr/eor in the inter-sample pads):
#   F = (S0>>6) ^ (S1>>4) ^ (S2>>2) ^ S3
# then cancels the constant CIA-port bits (A3, captured per block) and looks the
# result up in a 256-byte table (descramble) that inverts + reorders the data
# bits back into the byte. To save ROM the table isn't stored -- reset.s
# generates it into RAM at boot (_epyx_gen_descramble). The timed receive is
# hardware-only (VICE has no Epyx-transmit drive), but the generated TABLE and
# the fold math -- where a bug would hide -- are checkable here: read the table
# back from RAM and simulate the fold for all bytes and all constant patterns.

def _descramble(v):
    v.run_for(0.3)                          # let reset.s fill it post-zerobss
    return v.read_memory(_label_addr("descramble"), 256)


def _a3(const):                             # the per-block constant smear
    x = const & 0x1F
    return (x ^ (x >> 2) ^ (x >> 4)) & 0xFF


def _fold(s):                               # what the in-loop lsr/eor builds
    a = s[0]
    a = (a >> 2) ^ s[1]
    a = (a >> 2) ^ s[2]
    a = (a >> 2) ^ s[3]
    return a & 0xFF


def test_descramble_generated_in_ram(v):
    t = _descramble(v)
    for x in range(256):                    # folded value -> byte (invert+permute)
        inv = (~x) & 0xFF
        want = (((inv & 0x01) << 7) | ((inv & 0x02) << 4) | ((inv & 0x04) << 4)
                | ((inv & 0x08) << 1) | ((inv & 0x10) >> 1) | ((inv & 0x20) >> 4)
                | ((inv & 0x40) >> 4) | ((inv & 0x80) >> 7))
        assert t[x] == want, "descramble[$%02X]=$%02X want $%02X" % (x, t[x], want)


def test_full_deinterleave_roundtrip(v):
    # Encode each byte the way Meatloaf's transmitEpyxByte does (the two data bits
    # land inverted at $DD00 bits 6/7), fold + cancel + table the way the receiver
    # does, and check all 256 round-trip -- for several constant CIA-port patterns,
    # since A3 must make the result independent of those fixed low bits.
    t = _descramble(v)

    def encode(byte, const):
        d = [(byte >> i) & 1 for i in range(8)]

        def samp(b6, b7):                   # bits 0-4 = const, bit5=0 (DATA out)
            return (const & 0x1F) | ((1 - b6) << 6) | ((1 - b7) << 7)

        return [samp(d[7], d[5]), samp(d[6], d[4]),
                samp(d[3], d[1]), samp(d[2], d[0])]

    for const in range(0x20):               # every bits-0-4 pattern
        for byte in range(256):
            f = _fold(encode(byte, const)) ^ _a3(const)
            out = t[f]
            assert out == byte, \
                "const=$%02X round-trip $%02X -> $%02X" % (const, byte, out)
