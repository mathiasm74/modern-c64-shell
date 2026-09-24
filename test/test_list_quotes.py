"""Control codes inside a BASIC string are LISTed reversed, not executed.

cat/less print a program through the util bank's detokenizer (print mode),
which sends each quoted control code as RVS ON, glyph, RVS OFF -- so CHROUT
learned reverse mode ($12/$92, flag $C7, cleared by RETURN) like the stock
KERNAL. The glyphs follow scr_display (screen.s), the rule the editor draws
with and which was measured against the stock KERNAL:
    $00-$1F -> screen code c, reversed
    $80-$9F -> screen code (c & $1F) + $40, reversed
"""

import os
import shutil
import subprocess

from lib.overlays import seed_files

_HERE = os.path.dirname(os.path.abspath(__file__))
_DISK = os.path.join(_HERE, "data", "_scratch_quotes.d64")
_PRG = os.path.join(_HERE, "data", "_quotes.prg")

# 10 PRINT "{clr}{red}HI{rvs on}"
# 20 PRINT "OK"
_BODY1 = bytes([0x99, 0x20, 0x22, 0x93, 0x1C, 0x48, 0x49, 0x12, 0x22])
_BODY2 = bytes([0x99, 0x20, 0x22, 0x4F, 0x4B, 0x22])


def _program():
    out, addr = [], 0x0801
    for num, body in ((10, _BODY1), (20, _BODY2)):
        chunk = bytes([num & 0xFF, num >> 8]) + body + b"\x00"
        addr += 2 + len(chunk)
        out += [addr & 0xFF, addr >> 8] + list(chunk)
    return bytes([0x01, 0x08] + out + [0, 0])


_HAVE = shutil.which("c1541") is not None
if _HAVE:
    shutil.copy(os.path.join(_HERE, "data", "test.d64"), _DISK)
    open(_PRG, "wb").write(_program())
    _HAVE = subprocess.run(["c1541", "-attach", _DISK, "-write", _PRG, "quotes"],
                           capture_output=True).returncode == 0
VICE_DISK = "data/_scratch_quotes.d64"

CR = 0x0D
CLEAR = 0x93


def _send(v, codes):
    codes = [c if isinstance(c, int) else ord(c) for c in codes]
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def _wait(v, needle, tries=40, chunk=0.3):
    for _ in range(tries):
        if needle in v.screen_text():
            return True
        v.run_for(chunk)
    return needle in v.screen_text()


def _rev(c):
    """scr_display's glyph for a control code, reversed."""
    return (c | 0x80) if c < 0x20 else (((c & 0x1F) + 0x40) | 0x80)


def test_cat_shows_quoted_control_codes_reversed(v):
    if not _HAVE:
        print("      (skipped: no c1541)")
        return
    assert _wait(v, "8>", tries=80)
    seed_files(v)
    _send(v, [CLEAR] + list("cat quotes") + [CR])
    assert _wait(v, '20 PRINT "OK"'), \
        "no listing -- or the {clr} in the string cleared it\n%s" % v.screen_text()
    rows = v.screen_rows()
    r1 = next(i for i, r in enumerate(rows) if r.startswith("10 PRINT"))
    cells = v.read_memory(0x0400 + 40 * r1, 40)
    # 10 PRINT "  = 10 screen codes, then the string's contents
    want = [_rev(0x93), _rev(0x1C), 0x48, 0x49, _rev(0x12), 0x22]
    assert cells[10:16] == want, \
        "quoted control codes: got %s want %s" % (
            " ".join("%02X" % c for c in cells[10:16]),
            " ".join("%02X" % c for c in want))
    # RVS OFF after each one: nothing on the next line is reversed.
    r2 = next(i for i, r in enumerate(rows) if r.startswith("20 PRINT"))
    line2 = v.read_memory(0x0400 + 40 * r2, 12)
    assert all(c < 0x80 for c in line2), \
        "reverse mode leaked into the next line: %s" % line2


def test_zz_chrout_reverse_mode_and_return_ends_it(v):
    """$12 turns reverse on, and RETURN turns it off, as on the stock KERNAL.
    (Parks the CPU; the runner sorts by name, hence zz.)"""
    stub = []
    for c in (CLEAR, 0x12, ord("A"), 0x92, ord("B"), 0x12, ord("C"), CR, ord("D")):
        stub += [0xA9, c, 0x20, 0xD2, 0xFF]     # lda #c / jsr CHROUT
    stub += [0x4C, 0x00, 0x00]                  # jmp * (patched below)
    here = 0x0900 + len(stub) - 3
    stub[-2:] = [here & 0xFF, here >> 8]
    v.write_memory(0x0900, stub)
    v.run_at(0x0900, 0.3)
    row0 = v.read_memory(0x0400, 3)
    assert row0 == [0x41 | 0x80, 0x42, 0x43 | 0x80], \
        "RVS ON/OFF: row 0 is %s" % row0
    assert v.read_byte(0x0400 + 40) == 0x44, \
        "RETURN did not end reverse mode: $%02X" % v.read_byte(0x0400 + 40)
