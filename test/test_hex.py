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
        for _ in range(80):             # ~4s: generous, since it exits early
            v.run_for(0.05)
            if v.read_byte(0x00C6) == 0:
                break


def _wait(v, needle, tries=40, chunk=0.15):
    for _ in range(tries):
        if needle in v.screen_text():
            return True
        v.run_for(chunk)
    return needle in v.screen_text()


def _to_prompt(v):
    """Get back to the shell, wherever the last test left us.

    These tests share one VICE, and the editor blocks: if a previous test failed
    mid-edit, or its ^X hit the "discard changes?" prompt, the machine is still
    IN the editor -- and then this test's command line is typed into the editor
    instead of the shell, editing the fixture's bytes and failing for a reason
    that has nothing to do with what it checks. Leaving that to luck is what made
    this module fail as a block under host load.
    """
    for _ in range(3):
        text = v.screen_text()
        if "discard" in text:
            _keys(v, "y")
        elif text.startswith("hex:"):
            _keys(v, [CTRL_X])
        else:
            return
        v.run_for(0.3)


def _open_hex(v, name):
    """Open a file, from a known-clean screen.

    `clear` first, and the dump row is LOCATED rather than assumed: the editor
    clears on exit, so a stale title from a previous test could otherwise still
    be on screen and satisfy the wait while the rows below it are blank.
    """
    seed_hex(v)
    v.run_for(0.3)
    _to_prompt(v)
    _keys(v, "clear")
    _keys(v, [CR])
    v.run_for(0.3)
    _keys(v, "hex " + name)
    _keys(v, [CR])
    if not _wait(v, "hex: " + name):
        return False
    # The title is not enough: render() draws it FIRST and the 22 dump rows
    # after, so matching the title can return while the dump is still being
    # painted -- anything the test then writes to the screen gets overwritten as
    # the paint finishes. The help line is drawn LAST, so it means "done".
    return _wait(v, "^x exit")


def _close_hex(v):
    """Leave the editor, whatever state it is in.

    ^X on a modified file asks "discard changes? y/n" and BLOCKS until answered,
    so a teardown that only sends ^X can leave the editor running -- and then the
    next test types its command line into the editor instead of the shell. That
    cascaded one real failure into all four other tests in this module.
    """
    _keys(v, [CTRL_X])
    v.run_for(0.3)
    if "discard" in v.screen_text():
        _keys(v, "y")
    _wait(v, "8>")


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


def test_hex_uses_the_shells_text_colour(v):
    """Not a hardcoded colour.

    fill_color() used to write $0E (light blue) with a comment calling it "the
    shell's default" -- it is the bare machine's default. Tardis boots on a
    dark-red background, so the editor came up blue on red and was barely
    readable (hardware-reported). Set an unmistakable colour first and require
    the editor to honour it, which also makes `text <n>` apply here.
    """
    seed_hex(v)
    v.run_for(0.3)
    _to_prompt(v)
    _keys(v, "clear")
    _keys(v, [CR])
    v.run_for(0.3)
    # Write $0286 directly rather than using `text`: that command lives in the
    # FILES bank and these tests seed only the hex bank, so it would silently do
    # nothing. What matters here is that the editor follows $0286 whoever set it.
    want = 7                            # yellow: neither $0E nor the default
    v.write_byte(0x0286, want)

    _keys(v, "hex readme")
    _keys(v, [CR])
    assert _wait(v, "hex: readme"), "hex did not open\n%s" % v.screen_text()

    # Colour RAM across the dump area must be the shell's colour throughout.
    cram = v.read_memory(0xD800, 1000)
    off = [i for i in range(1000) if (cram[i] & 0x0F) != want]
    assert not off, \
        "%d of 1000 cells are not the shell's colour %d (first at %d, colour %d)" \
        % (len(off), want, off[0], cram[off[0]] & 0x0F)

    _close_hex(v)


def test_hex_cursor_move_does_not_repaint_the_dump(v):
    """A cursor move must touch the two cursor cells, not all 22 dump rows.

    Repainting everything on every keypress made the whole screen flicker
    (hardware-reported): the VIC reads the screen while we write it, so 1000
    cells of clear-then-fill per keystroke is visible. The direct way to assert
    the light path: scribble a sentinel into a dump row the cursor is not on,
    move the cursor WITHOUT scrolling, and require the sentinel to survive. A
    full repaint would erase it.
    """
    assert _open_hex(v, "readme"), "hex did not open\n%s" % v.screen_text()

    # Row 5 of the dump (screen row 6) is far from the cursor, which starts on
    # dump row 0, and a single cursor-right cannot scroll to it.
    cell = 0x0400 + 6 * 40 + 20
    v.write_byte(cell, 0x51)             # a ball glyph: nothing else draws it
    # TWICE: in the hex pane the first cursor-right steps to the byte's second
    # nibble, and only the second advances to the next byte. Both take the light
    # path, since neither scrolls.
    _keys(v, [K_RIGHT, K_RIGHT])
    v.run_for(0.3)

    assert v.read_byte(cell) == 0x51, \
        "the dump was repainted on a cursor move (sentinel gone)"

    # And the move really did happen -- otherwise the test proves nothing.
    assert "at 0001" in v.screen_rows()[0].lower(), \
        "the cursor did not move:\n%s" % v.screen_rows()[0]

    _close_hex(v)
