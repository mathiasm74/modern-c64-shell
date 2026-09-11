"""load, and the run autostart stub (Phase 6/8 + the run-to-stock swap).

`run` now starts a loaded program in a real STOCK environment: it plants a
CBM80 autostart stub in the tape buffer, points a CBM80 structure at $8000
to it, and swaps the One ROM to the stock ROMs via the RBCP protocol -- the
stock KERNAL reset then autostarts the stub. Like runstock, the swap is
hardware-only (VICE has no One ROM model, so the swap is inert and the JMP
through (FFFC) would re-enter our reset and re-detect the planted CBM80).
So we can't exercise `run` end-to-end in VICE; instead we verify `load`
works and that the run-stub is assembled correctly (read out of ROM, like
test_keyboard checks the keytab). The stub's execution is hardware-tested.
"""

import os

from lib.overlays import seed_disk_bank   # `load` lives in the disk bank now

VICE_DISK = "data/test.d64"

_LABELS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "build", "labels.txt")


def _labels():
    out = {}
    with open(_LABELS) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 3 and parts[0] == "al":
                out[parts[2].lstrip(".")] = int(parts[1], 16) & 0xFFFF
    return out


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [0x0D])
    v.write_byte(0x00C6, len(text) + 1)


def _wait_for(v, needle, tries=8, chunk=0.5):
    for _ in range(tries):
        v.run_for(chunk)
        if needle in v.screen_text():
            return True
    return False


def test_load_completes(v):
    seed_disk_bank(v)
    v.run_for(0.3)
    _type(v, "load prog")
    assert _wait_for(v, "loaded $"), \
        "load never completed\n%s" % v.screen_text()


def test_load_missing_reports_not_found(v):
    """A missing file streams back no data (immediate EOI, no timeout); load
    must say so rather than read $00,$00 as a load address and print a bogus
    "loaded $0000-$0000". It now reports the drive's own error-channel status,
    so a 1541 says "62 FILE NOT FOUND" (a networked Meatloaf that's offline says
    "74 DRIVE NOT READY" instead -- hardware-only)."""
    seed_disk_bank(v)
    v.run_for(0.3)
    _type(v, "load nosuchfile")
    found = _wait_for(v, "FILE NOT FOUND")
    txt = v.screen_text()
    assert "loaded $0000" not in txt, \
        "missing-file load printed a bogus load range\n%s" % txt
    assert found, \
        "missing-file load did not report the drive status\n%s" % txt


def _find(seq, sub):
    for i in range(len(seq) - len(sub) + 1):
        if list(seq[i:i + len(sub)]) == sub:
            return i
    return -1


def test_run_stub_assembled_correctly(v):
    # Can't run the swap in VICE; read the stub out of KERNAL ROM and check
    # the key structure: takes the machine (SEI), inits via the KERNAL
    # vectors, has the BASIC init-without-NEW ($E3BF), auto-runs by typing "RUN"
    # into the keyboard buffer and dropping to READY ($A474) rather than
    # JMP $A7AE (which was blank across the real bank swap), and keeps the
    # machine-code fallback JMP ($CFF8).
    L = _labels()
    start = L["_run_stub"]
    end = L["_run_stub_end"]
    assert 0xE000 <= start < end <= 0xFFFF, \
        "run_stub not in KERNAL ROM ($%04X-$%04X)" % (start, end)
    b = v.read_memory(start, end - start)
    assert b[0] == 0x78, "run_stub must start with SEI, got $%02X" % b[0]
    assert _find(b, [0x20, 0x84, 0xFF]) >= 0, "no JSR $FF84 (IOINIT)"
    assert _find(b, [0x20, 0x8A, 0xFF]) >= 0, "no JSR $FF8A (RESTOR)"
    assert _find(b, [0x20, 0x81, 0xFF]) >= 0, "no JSR $FF81 (CINT)"
    assert _find(b, [0x20, 0xBF, 0xE3]) >= 0, "no JSR $E3BF (BASIC init)"
    # auto-run: stuff "R" ($52) into the keyboard buffer ($0277) and JMP $A474.
    assert _find(b, [0xA9, 0x52, 0x8D, 0x77, 0x02]) >= 0, \
        "no LDA #\"R\" / STA $0277 (auto-typed RUN)"
    assert _find(b, [0x4C, 0x74, 0xA4]) >= 0, "no JMP $A474 (READY/auto-run)"
    assert _find(b, [0x4C, 0xAE, 0xA7]) < 0, \
        "stub still JMP $A7AE -- the fragile hand-rolled RUN was reintroduced"
    assert _find(b, [0x6C, 0xF8, 0xCF]) >= 0, "no JMP ($CFF8) ML fallback"
