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

from lib.overlays import seed_disk_bank

VICE_DISK = "data/test.d64"

# The Epyx code lives in the DISK BANK now (docs/ROM-EXPANSION.md), not in the
# 16KB ROM, so its symbols come from the bank's own label file and its bytes
# from the bank image. Everything below still runs in VICE because bank_call's
# RAM-backed path exists: seed_disk_bank() writes the image into the RAM under
# the $A000 ROM, and a stub clears LORAM to map it in before calling.
_BANK = os.path.join(os.path.dirname(__file__), "..", "build", "banks", "disk_bank.bin")
_LABELS = os.path.join(os.path.dirname(__file__), "..", "build", "banks",
                       "disk_bank.labels")
_BANK_BASE = 0xA000


def _label_addr(name):
    """Look up an exported asm label's address from the bank's label file."""
    with open(_LABELS) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 3 and parts[2].lstrip(".") == name:
                return int(parts[1], 16) & 0xFFFF
    raise AssertionError("label %r not found in %s" % (name, _LABELS))


def _bank_bytes(addr, n):
    """Read n bytes of the bank's ROM image at addr, from the file.

    Not via VICE: with the bank seeded into the RAM under $A000, a monitor read
    of $A000 still returns the BASIC-half ROM. The image is the source of truth
    for "is this byte-exact" checks anyway."""
    with open(_BANK, "rb") as f:
        img = f.read()
    off = addr - _BANK_BASE
    return list(img[off:off + n])


# LORAM off/on: map the seeded bank in over the BASIC half, and put it back.
_MAP_BANK = [0xA9, 0x36, 0x85, 0x01]            # LDA #$36 ; STA $01
_UNMAP_BANK = [0xA9, 0x37, 0x85, 0x01]          # LDA #$37 ; STA $01


def _call_bank(v, symbol, before=None, after=None, park=True):
    """Build+run a stub at $1000 that maps the bank in, JSRs symbol, unmaps."""
    addr = _label_addr(symbol)
    stub = list(before or [])
    stub += _MAP_BANK
    stub += [0x20, addr & 0xFF, (addr >> 8) & 0xFF]     # JSR <addr>
    # `after` runs BEFORE the unmap: restoring $01 needs LDA, which would
    # destroy the A/X the called routine returned.
    stub += list(after or [])
    stub += _UNMAP_BANK
    if park:
        pc = 0x1000 + len(stub)
        stub += [0x4C, pc & 0xFF, pc >> 8]              # JMP self
    v.write_memory(0x1000, stub)
    return stub


def test_epyx_upload_matches_meatloaf_v2v3_signature(v):
    """Step 1: the drive-side Epyx handshake. Meatloaf recognises the cartridge
    by three 25-byte M-W chunks whose 8-bit additive checksums are $53/$A6/$8F
    (IECFileDevice.cpp epyxV2V3sig), then M-E $01A9. It only sums the bytes, so
    our upload is clean-room filler -- but the sums must be exact. Read the 75
    bytes out of ROM and check each chunk. (The actual Epyx-mode handoff only
    happens on a real Meatloaf; VICE's 1541 can't model it, so this verifies
    the one thing that must be byte-exact.)"""
    seed_disk_bank(v)
    data = _bank_bytes(_label_addr("_fastload_epyx_upload"), 3 * 0x19)
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
# bits back into the byte, assembled into the bank's ROM. The timed receive is
# hardware-only (VICE has no Epyx-transmit drive), but the TABLE and the fold
# math -- where a bug would hide -- are checkable here: read the table out of
# the image and simulate the fold for all bytes and all constant patterns.

def _descramble(v):
    """The descramble table, read out of the bank's ROM image.

    It used to be generated into RAM (by reset.s, then by the bank's per-entry
    init), so this used to have to run the generator on the emulated machine.
    It is assembled at build time now -- bank ROM is spare, but bank RAM is
    carved out of the program load area -- so the table is simply data in the
    image, and `v` is unused.
    """
    return _bank_bytes(_label_addr("descramble"), 256)


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


# --- ready-timeout = failure, not EOF --------------------------------------
# The drive ends a transfer in-band with a zero-length block; a ready timeout
# in _epyx_wait_ready is always an error (dead/aborted drive). next_byte flags
# it in TMOFL ($02AB) and _epyx_recv_prg must report failure ($0000) even if
# data already arrived -- otherwise a drive dying mid-file would be reported
# as a successful (truncated) load. The timed transmit can't run in VICE, but
# the timeout path can: pulling CLK low from the C64 side (CLK OUT, $DD00 bit
# 4) holds the wired-AND bus line low, so wait_clk_hi never sees "ready" and
# the full retry ladder (~11s emulated) runs dry. The mid-stream variant
# (blocks, then a stall) needs an Epyx sender, so the TOTL>=3 ordering at @eof
# is hardware-validated; this covers the flag set + the failure return.

TMOFL = 0x02AB


def test_recv_prg_ready_timeout_fails_and_flags(v):
    seed_disk_bank(v)
    _call_bank(
        v, "_epyx_recv_prg",
        before=[
            0xAD, 0x00, 0xDD,               # LDA $DD00
            0x09, 0x10,                     # ORA #$10      (pull CLK low)
            0x8D, 0x00, 0xDD,               # STA $DD00
        ],
        after=[
            0x8D, 0xF0, 0x10,               # STA $10F0     (end address lo)
            0x8E, 0xF1, 0x10,               # STX $10F1     (end address hi)
            0xA9, 0x01,
            0x8D, 0xF2, 0x10,               # STA $10F2     (done marker)
        ])
    v.write_memory(0x10F0, [0xEE, 0xEE, 0xEE])  # sentinels
    v.write_byte(TMOFL, 0xEE)                   # prove recv_prg writes it
    v.run_at(0x1000, 1.0)
    for _ in range(40):                          # ~11s emulated, warp is fast
        if v.read_byte(0x10F2) == 0x01:
            break
        v.run_for(2.0)
    assert v.read_byte(0x10F2) == 0x01, "recv_prg never returned (wedged?)"
    assert v.read_memory(0x10F0, 2) == [0x00, 0x00], \
        "timeout must return $0000 (failure), got $%02X%02X" \
        % (v.read_byte(0x10F1), v.read_byte(0x10F0))
    assert v.read_byte(TMOFL) == 0x01, "TMOFL not set on ready timeout"
