"""KLOAD fast-loads only the device the shell confirmed is Meatloaf-class.

KLOAD is our LOAD wedge in the stock KERNAL (src/kload.s), live after `run` and
`basic`. Its fast path M-E's the Epyx fingerprint -- 75 bytes of $EA filler that
a Meatloaf only checksums. A real 1541 EXECUTES it, runs off into its stack page
and dies; KLOAD then fell back to the stock loader, which waited on the dead
drive for ever. So with a real 1541, EVERY load under stock hung the machine:
`,8`, `,8,1` and `LOAD"$",8` alike. (`fload` had the same bug and learned to
probe first in v0.2.48; KLOAD never did.)

Now the disk bank's probe (M-R $FFFC) records the Meatloaf-class device at
$03A5, the swap pokes it into KLOAD's kl_dev ($FBA6), and KLOAD sends any other
device straight to the stock loader, before a byte goes to the drive.

The swap itself is inert in VICE, so the chain is tested in its three links:
the probe clears a stale claim, KLOAD is built to check kl_dev, and a stock
KERNAL carrying the patch with kl_dev = 0 loads from a real 1541.
"""

import os
import re
import shutil
import sys
import time

from lib.overlays import seed_disk_bank

VICE_DISK = "data/test.d64"

_HERE = os.path.dirname(os.path.abspath(__file__))
_BUILD = os.path.join(_HERE, "..", "build")
_STOCK_K = os.path.join(_HERE, "..", "stock-roms", "kernal.901227-03.bin")
_STOCK_B = os.path.join(_HERE, "..", "stock-roms", "basic.901226-01.bin")

KL_MEATDEV = 0x03A5
MB_DEV = 0x02D1
KL_DEV = 0xFBA6                          # first byte of KLOAD's KLDATA piece
E_PROBE = 0xA013                         # disk bank entry 5 (crt0_disk.s)

# test/data/test.d64's `prog` (loads at $2000; `,8` puts it at $0801).
PROG = [0xA2, 0x00, 0xBD, 0x0E, 0x20, 0xF0, 0x06, 0x20]


def _labels(path):
    syms = {}
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) >= 3 and p[0] == "al":
                syms[p[2].lstrip(".")] = int(p[1], 16) & 0xFFFF
    return syms


def test_probe_clears_a_stale_meatloaf_claim_for_a_real_1541(v):
    """A real 1541 must never be left recorded as Meatloaf-class: that is what
    would arm KLOAD's fast path for it. Seed the claim, probe, and watch the
    probe take it back."""
    for _ in range(20):
        v.run_for(0.3)
        if "8>" in v.screen_text():
            break
    seed_disk_bank(v)
    v.write_byte(KL_MEATDEV, 8)
    v.write_byte(MB_DEV, 8)
    v.write_byte(0x10F0, 0)
    v.write_memory(0x1000, [
        0x78,                             # SEI: the shell's IRQ uses $01 too
        0xA9, 0x36, 0x85, 0x01,           # map the seeded bank in
        0x20, E_PROBE & 0xFF, E_PROBE >> 8,
        0xA9, 0x37, 0x85, 0x01,           # and back out
        0xA9, 0x01, 0x8D, 0xF0, 0x10,     # done marker
        0x4C, 0x11, 0x10,                 # park
    ])
    v.run_at(0x1000, 1.0)
    for _ in range(20):
        if v.read_byte(0x10F0) == 1:
            break
        v.run_for(0.5)
    assert v.read_byte(0x10F0) == 1, "the probe entry never returned"
    assert v.read_byte(KL_MEATDEV) == 0, (
        "a real 1541 left $03A5 = %d: the stock swap would arm KLOAD's fast "
        "path for it, and its first LOAD would hang the drive"
        % v.read_byte(KL_MEATDEV))


def test_kload_checks_kl_dev_before_the_fast_path(v):
    """kl_dev must sit where launch.s pokes it, and the entry must compare FA
    against it and bail to the stock loader -- before kl_fast is reached."""
    (void) = v
    syms = _labels(os.path.join(_BUILD, "kload.labels"))
    assert syms.get("kl_dev") == KL_DEV, (
        "kl_dev is at $%04X, but launch.s pokes $%04X (KLOAD2_SLOT_OFF): it "
        "must stay FIRST in KLDATA" % (syms.get("kl_dev") or 0, KL_DEV))
    body = open(os.path.join(_BUILD, "kload.bin"), "rb").read()
    cmp_at = body.find(bytes([0xCD, KL_DEV & 0xFF, KL_DEV >> 8]))
    assert cmp_at >= 0, "KLOAD never compares FA against kl_dev"
    fast = syms["kl_fast"]
    jsr_at = body.find(bytes([0x20, fast & 0xFF, fast >> 8]))
    assert 0 <= cmp_at < jsr_at, "the kl_dev check must come before kl_fast"
    img2 = open(os.path.join(_BUILD, "kload2.bin"), "rb").read()
    assert img2[0] == 0, "kl_dev must default to 0 (no fast path) in the image"


def _patched_stock_kernal(path, kl_dev):
    """The stock KERNAL as the swap leaves it: KLOAD's pieces in the tape space,
    ILOAD's table entry at $FD4C pointed at it, and kl_dev poked."""
    k = bytearray(open(_STOCK_K, "rb").read())

    def put(addr, data):
        k[addr - 0xE000:addr - 0xE000 + len(data)] = data
    put(0xF8E2, open(os.path.join(_BUILD, "kload.bin"), "rb").read())
    put(0xFBA6, open(os.path.join(_BUILD, "kload2.bin"), "rb").read())
    put(0xFD4C, bytes([0xE2, 0xF8]))
    put(KL_DEV, bytes([kl_dev]))
    with open(path, "wb") as f:
        f.write(k)


def test_patched_stock_kernal_loads_from_a_real_1541(v):
    """With kl_dev = 0 -- what the swap pokes when the probe found a real 1541
    -- a `,8` load under the patched stock KERNAL must complete. Before the
    gate it printed SEARCHING twice (KLOAD's, then the fallback's) and never
    came back."""
    (void) = v
    if not (os.path.exists(_STOCK_K) and os.path.exists(_STOCK_B)):
        print("      (skipped: no stock ROMs in stock-roms/)")
        return
    kern = os.path.join(_BUILD, "kernal-kload-test.bin")
    _patched_stock_kernal(kern, 0)
    disk = os.path.join(_HERE, "data", "_scratch_kload.d64")
    shutil.copy(os.path.join(_HERE, "data", "test.d64"), disk)
    sys.path.insert(0, os.path.join(_HERE, "lib"))
    from vice import Vice
    with Vice(kernal=kern, basic=_STOCK_B, disk=disk) as sv:
        for _ in range(20):
            sv.run_for(0.3)
            if "ready." in sv.screen_text():
                break
        for chunk in ('LOAD"PROG', '",8\n'):     # uppercase = PETSCII letters
            sv.inject_keys(chunk)
            sv.run_for(0.3)
        for _ in range(40):
            sv.run_for(0.5)
            rows = [r for r in sv.screen_rows() if r.strip()]
            if rows[-1].strip() == "ready." and "loading" in sv.screen_text():
                break
        text = sv.screen_text()
        assert text.count("searching for prog") == 1, (
            "KLOAD tried the fast path on a real 1541 (a second SEARCHING is "
            "the stock fallback's):\n%s" % text)
        got = list(sv.read_memory(0x0801, len(PROG)))
        assert got == PROG, (
            "LOAD\"PROG\",8 did not complete under the patched stock KERNAL "
            "-- got %s at $0801\n%s"
            % (" ".join("%02X" % b for b in got), text))
