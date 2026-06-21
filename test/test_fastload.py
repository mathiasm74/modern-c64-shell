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


# --- Epyx receiver de-interleave table ------------------------------------
# The fast receiver (_epyx_recv_byte) turns the 4 raw $DD00 samples of a byte
# into the byte via a 256-byte lookup table (detab). To save ROM the table isn't
# stored -- reset.s generates it into RAM at boot (_epyx_gen_detab) from a 4-byte
# seed. The timed receive is hardware-only (VICE has no Epyx-transmit drive), but
# the generated TABLE -- where a bug would hide -- is data we read back from RAM.
# A sample byte s carries two data bits inverted on the wire (~s.bit6, ~s.bit7);
# detab[s] places them at result bits 7/5, and shifting the loaded value right
# slides the pair to each sample's positions. A full byte is
#   detab[S0] | (detab[S1]>>1) | (detab[S2]>>4) | (detab[S3]>>5)
# with S0..S3 carrying (d7,d5) (d6,d4) (d3,d1) (d2,d0).

def _detab(v):
    v.run_for(0.3)                          # let reset.s/_epyx_gen_detab fill it
    return v.read_memory(_label_addr("detab"), 256)


def test_detab_generated_in_ram(v):
    tab = _detab(v)
    for s in range(256):
        b6, b7 = (s >> 6) & 1, (s >> 7) & 1
        want = ((1 - b6) << 7) | ((1 - b7) << 5)
        assert tab[s] == want, "detab[%d]=$%02X want $%02X" % (s, tab[s], want)


def test_full_deinterleave_roundtrip(v):
    # Encode each byte the way Meatloaf's transmitEpyxByte does, then decode it
    # through the table the way the receiver does, and check all 256 round-trip.
    t = _detab(v)

    def sample(bit6, bit7):                 # one inverted $DD00 sample
        return ((1 - bit6) << 6) | ((1 - bit7) << 7)

    for byte in range(256):
        d = [(byte >> i) & 1 for i in range(8)]
        s0, s1, s2, s3 = (sample(d[7], d[5]), sample(d[6], d[4]),
                          sample(d[3], d[1]), sample(d[2], d[0]))
        out = t[s0] | (t[s1] >> 1) | (t[s2] >> 4) | (t[s3] >> 5)
        assert out == byte, "round-trip $%02X -> $%02X" % (byte, out)
