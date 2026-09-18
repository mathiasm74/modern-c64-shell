"""Manual probe for the drive1541 work -- NOT a test (run_tests only collects
test_*.py). It exists because several rounds of this calibration were
invalidated by a stale cartridge that make believed was current, so it refuses
to measure unless the .crt actually contains the drive blob currently on disk.

Use it from a throwaway test_*.py:  from calib import measure; measure("label")
"""
import hashlib
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "lib"))
_ROOT = os.path.join(_HERE, "..")
_K = os.path.join(_ROOT, "stock-roms", "kernal.901227-03.bin")
_B = os.path.join(_ROOT, "stock-roms", "basic.901226-01.bin")
_D = os.path.join(_HERE, "data", "test.d64")
_CRT = os.path.join(_ROOT, "build", "ef", "tardis.crt")
_BLOB = os.path.join(_ROOT, "build", "drive1541.bin")


def verify_cart():
    """Prove the .crt actually carries the drive blob currently on disk.

    Every earlier run of this experiment was invalidated by a stale (in one
    case zero-byte) cartridge that make believed was current, so the
    measurement now refuses to proceed unless the artifact matches.
    """
    crt = open(_CRT, "rb").read()
    blob = open(_BLOB, "rb").read()
    assert len(crt) > 1000, "tardis.crt is %d bytes -- the build failed" % len(crt)
    found = blob in crt
    print("   cart %d bytes, blob %d bytes (md5 %s) present in cart: %s"
          % (len(crt), len(blob), hashlib.md5(blob).hexdigest()[:8],
             "YES" if found else "NO -- STALE, MEASUREMENT INVALID"))
    assert found, "the cartridge does not contain the current drive1541.bin"


def _type(sv, text):
    for chunk in [text[i:i + 9] for i in range(0, len(text), 9)]:
        sv.inject_keys(chunk)
        for _ in range(80):
            sv.run_for(0.1)
            if sv.read_byte(0xC6) == 0:
                break
    sv.run_for(3.0)


def measure(label):
    verify_cart()
    from vice import Vice
    with Vice(kernal=_K, basic=_B, disk=_D,
              extra_args=["-cartcrt", _CRT, "+easyflashjumper"]) as sv:
        for _ in range(60):
            sv.run_for(0.25)
            if "8: " in sv.screen_text() or "8>" in sv.screen_text():
                break
        sv.write_memory(0x02AC, [0, 0, 0])
        _type(sv, "clear\r")
        _type(sv, "fload prog\r")
        sv.run_for(2.0)
        # Unambiguous signals only. $02AC/$02AE are the receiver's OWN TOTL and
        # DOTS counters -- reading them as if they were probe output produced
        # several meaningless comparisons.
        got = bytes(sv.read_memory(0x2000, 8))
        lad = sv.read_byte(0x02AF) | (sv.read_byte(0x02B0) << 8)
        total = sv.read_byte(0x02AC) | (sv.read_byte(0x02AD) << 8)
        print("   [%s]" % label)
        print("     load addr decoded $%04X (want $2000) | bytes received %d "
              "(want 33) | timeout %d" % (lad, total, sv.read_byte(0x02AB)))
        print("     $2000 = %s   %s" % (got.hex(' '),
              "LOADED CORRECTLY" if got.startswith(b"\xa2\x00\xbd") else "wrong/no data"))
        print("   [%s] drive: %s" % (label,
              " ".join(sv._command("m 8:0514 8:051f").split())[8:50]))
