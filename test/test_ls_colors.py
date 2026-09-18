"""`ls` colors what you can run or enter, and leaves data in the text color.

The rule, as in Unix `ls` (type_color in src/banks/dir.c): PRG light green;
DIR, URL and disk images yellow; SEQ and USR in the user's own text color;
REL and DEL grey. test_disk covers PRG vs SEQ on the shared fixture; this module
brings its own disk for USR, which used to share yellow with URL -- the only
check was the first letter -- and so read as something you could cd into.

The text color is set to something other than the boot default first, so
"plain" is proven to mean the user's color, not a fixed one that happens to
match it.
"""

import os
import shutil
import subprocess

from lib.overlays import seed_disk_bank

_HERE = os.path.dirname(os.path.abspath(__file__))
_DISK = os.path.join(_HERE, "data", "_scratch_colors.d64")


def _make_disk():
    c1541 = shutil.which("c1541")
    if not c1541:
        return False
    src = _DISK + ".bin"
    with open(src, "wb") as f:
        f.write(bytes([0x00, 0x20, 0x60]))
    if os.path.exists(_DISK):
        os.remove(_DISK)
    subprocess.run([c1541, "-format", "colors,01", "d64", _DISK,
                    "-write", src, "prog",
                    "-write", src, "notes,s",
                    "-write", src, "blob,u"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   check=True)
    os.remove(src)
    return True


_HAVE = _make_disk()
VICE_DISK = "data/_scratch_colors.d64" if _HAVE else None

TEXT_COLOR = 0x0286
USER_TEXT = 0x0F                        # light grey: not the boot default


def _type(v, text):
    codes = [0x93] + [ord(c) for c in text] + [0x0D]
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))


def test_ls_colors_by_what_you_can_do_with_a_file(v):
    if not _HAVE:
        print("      (skipped: c1541 not available)")
        return
    for _ in range(20):
        v.run_for(0.3)
        if "8>" in v.screen_text():
            break
    seed_disk_bank(v)
    v.write_byte(TEXT_COLOR, USER_TEXT)
    _type(v, "ls")
    for _ in range(20):
        v.run_for(0.8)
        if "BLOB" in v.screen_text():
            break
    rows = v.screen_rows()

    def color_at(name):
        for i, r in enumerate(rows):
            for off in (0, 20):
                if r[off:off + len(name)] == name and \
                        r[off + len(name):off + len(name) + 1] in (" ", ""):
                    return v.read_byte(0xD800 + i * 40 + off) & 0x0F
        return None

    got = {n: color_at(n) for n in ("PROG", "NOTES", "BLOB")}
    assert None not in got.values(), "ls did not list all three:\n%s" \
        % v.screen_text()
    assert got["PROG"] == 0x0D, "PRG should be light green, got %d" % got["PROG"]
    assert got["NOTES"] == USER_TEXT, (
        "SEQ should be the user's text color (%d), got %d"
        % (USER_TEXT, got["NOTES"]))
    assert got["BLOB"] == USER_TEXT, (
        "USR should be the user's text color (%d), got %d -- yellow would make "
        "it look like a URL or folder you can cd into"
        % (USER_TEXT, got["BLOB"]))
