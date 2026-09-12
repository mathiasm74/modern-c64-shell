"""The hex editor bank (src/banks/hex.c).

A byte editor: the whole file is held at $0800 in user RAM, shown as an address
column plus hex and PETSCII panes, edited in place and written back. Whole-file
rather than paged because a CBM drive has no cheap seek -- a paged window would
re-read from the start on every scroll.

These run on a throwaway copy of the fixture, since saving mutates it.
"""

import os
import shutil

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copyfile(os.path.join(_HERE, "data", "test.d64"),
                os.path.join(_HERE, "data", "_scratch_hex.d64"))
VICE_DISK = "data/_scratch_hex.d64"

from lib.overlays import seed_hex

CR = 0x0D
TAB = 0x09
CTRL_X = 0x18
CTRL_O = 0x0F
K_RIGHT = 0x1D


def _keys(v, codes):
    codes = [c if isinstance(c, int) else ord(c) for c in codes]
    while codes:
        chunk, codes = codes[:8], codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        for _ in range(30):
            v.run_for(0.05)
            if v.read_byte(0x00C6) == 0:
                break


def _wait(v, needle, tries=40, chunk=0.15):
    for _ in range(tries):
        if needle in v.screen_text():
            return True
        v.run_for(chunk)
    return needle in v.screen_text()


def _open_hex(v, name):
    """Open a file, from a known-clean screen.

    `clear` first, and the dump row is LOCATED rather than assumed: the editor
    clears on exit, so a stale title from a previous test could otherwise still
    be on screen and satisfy the wait while the rows below it are blank.
    """
    seed_hex(v)
    v.run_for(0.3)
    _keys(v, "clear")
    _keys(v, [CR])
    v.run_for(0.3)
    _keys(v, "hex " + name)
    _keys(v, [CR])
    return _wait(v, "hex: " + name)


def _dump_row(v, n=0):
    """The n-th dump row, found by its address column."""
    for r in v.screen_rows():
        if r.startswith("%04x" % (n * 8)):
            return r
    return ""


def test_hex_shows_the_bytes_of_a_file(v):
    """The dump shows the file's real bytes -- including a PRG's load address,
    which is data here, not something to hide."""
    # readme, not prog: another test saves over prog's first byte, and a display
    # test should not depend on whether it ran first.
    assert _open_hex(v, "readme"), "hex did not open\n%s" % v.screen_text()

    row = _dump_row(v, 0)
    assert row, "no dump row found\n%s" % v.screen_text()
    # readme.prg is $00 $20 (load address $2000) then "C64 SHELL TEST DISK"
    assert "00 20" in row, "load address not shown as data: %r" % row
    # ...and the PETSCII pane shows the text of those same bytes
    assert "c64 sh" in row.lower(), "character pane missing: %r" % row
    assert _dump_row(v, 1), "second dump row missing"

    _keys(v, [CTRL_X])
    _wait(v, "8>")


def test_hex_edits_a_byte_and_saves(v):
    """Typing hex digits overwrites the byte under the cursor, and the change
    survives a save and reload. Overwrite, never insert: a hex editor must not
    change the file's length."""
    assert _open_hex(v, "prog"), "hex did not open\n%s" % v.screen_text()

    before = v.read_memory(0x0800, 4)
    _keys(v, "ff")                      # both nibbles of byte 0
    v.run_for(0.3)
    after = v.read_memory(0x0800, 4)
    assert after[0] == 0xFF, "byte not edited: %s" % [hex(b) for b in after]
    assert after[1:] == before[1:], "edit spilled into neighbours"
    assert "*" in v.screen_text().split("\n")[0], "modified flag not shown"

    _keys(v, [CTRL_O])
    assert _wait(v, "wrote"), "save failed\n%s" % v.screen_text()
    _keys(v, [CTRL_X])
    _wait(v, "8>")

    assert _open_hex(v, "prog"), "could not reopen"
    assert v.read_memory(0x0800, 1)[0] == 0xFF, "edit did not survive the save"
    _keys(v, [CTRL_X])
    _wait(v, "8>")


def test_hex_petscii_pane_writes_the_byte(v):
    """TAB switches to the character pane, where the key typed IS the byte."""
    assert _open_hex(v, "readme"), "hex did not open\n%s" % v.screen_text()

    _keys(v, [TAB])
    _keys(v, "z")
    v.run_for(0.3)
    assert v.read_memory(0x0800, 1)[0] == ord("z"), \
        "character pane did not write the byte"

    _keys(v, [CTRL_X])
    v.run_for(0.3)
    _keys(v, "y")                       # discard
    _wait(v, "8>")
