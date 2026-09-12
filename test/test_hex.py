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
K_LEFT = 0x9D
K_HOME = 0x13


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

    # Everything outside the two data panes follows $0286: the title, the address
    # column and the help line. (The panes take a dimmer colour derived from the
    # background instead -- see test_hex_panes_are_dimmer_than_the_address_column;
    # this test is about the editor not hardcoding a colour of its own.)
    probes = [(0, 0), (0, 5),            # title row
              (1, 0), (1, 3),            # address column, first dump row
              (12, 0), (12, 2),          # ...and mid-dump
              (24, 0), (24, 4)]          # help line
    bad = [(r, c, _cram(v, r, c)) for r, c in probes if _cram(v, r, c) != want]
    assert not bad, \
        "these cells are not the shell's colour %d: %s" % (want, bad)

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


# Must match hex.c
_PANE_COLOR = [0x0C, 0x0C, 0x0A, 0x01, 0x01, 0x0D, 0x0E, 0x0C,
               0x07, 0x08, 0x01, 0x0C, 0x0F, 0x01, 0x01, 0x01]
COL_FOCUS = 0x01                        # white
COL_MIRROR = 0x0F                       # light grey


def _cram(v, row, col):
    return v.read_byte(0xD800 + row * 40 + col) & 0x0F


def test_hex_panes_are_dimmer_than_the_address_column(v):
    """The two data panes take a dimmer colour derived from the BACKGROUND.

    With the shell's dark-red ground that is light red, so the hex and PETSCII
    columns read as one block and the address column, the cursor and its
    companion cell stand out of them. The mapping is a table because the C64
    palette has a genuine light/dark sibling only for some hues -- there is no
    arithmetic for it -- so the table is the thing that can be mistyped, and this
    reads the live background rather than assuming red.
    """
    assert _open_hex(v, "readme"), "hex did not open\n%s" % v.screen_text()

    bg = v.read_byte(0xD021) & 0x0F
    want = _PANE_COLOR[bg]

    # Dump row 1 (screen row 2) is not the cursor's row, so nothing overrides it.
    assert _cram(v, 2, 6) == want, \
        "hex pane on background %d is colour %d, expected %d" \
        % (bg, _cram(v, 2, 6), want)
    assert _cram(v, 2, 31) == want, \
        "PETSCII pane on background %d is colour %d, expected %d" \
        % (bg, _cram(v, 2, 31), want)
    # The address column keeps the shell's text colour: that contrast is the point.
    assert _cram(v, 2, 0) == (v.read_byte(0x0286) & 0x0F), \
        "the address column should stay the shell's text colour, got %d" \
        % _cram(v, 2, 0)

    _close_hex(v)


def test_hex_cursor_colours_focus_and_companion_and_cleans_up(v):
    """Focus cell white, the same byte in the other pane light grey -- and both
    put BACK when the cursor moves.

    The restore is the half that breaks: cursor_off has to hand those cells their
    pane colour back, and without it the cursor leaves a trail of white and grey
    cells across the dump. Since a cursor move deliberately does NOT repaint
    (v0.2.13), nothing else would ever clean them up.
    """
    assert _open_hex(v, "readme"), "hex did not open\n%s" % v.screen_text()

    want = _PANE_COLOR[v.read_byte(0xD021) & 0x0F]
    # Cursor starts on byte 0: hex digit at col 5, its character at col 30.
    assert _cram(v, 1, 5) == COL_FOCUS, \
        "focus cell is colour %d, expected white" % _cram(v, 1, 5)
    assert _cram(v, 1, 30) == COL_MIRROR, \
        "the companion cell in the other pane is colour %d, expected light grey" \
        % _cram(v, 1, 30)

    # Move off byte 0 entirely (two rights: nibble, then byte).
    _keys(v, [K_RIGHT, K_RIGHT])
    v.run_for(0.3)

    assert _cram(v, 1, 5) == want, \
        "the old focus cell stayed colour %d -- the cursor leaves a white trail" \
        % _cram(v, 1, 5)
    assert _cram(v, 1, 30) == want, \
        "the old companion cell stayed colour %d -- grey trail" % _cram(v, 1, 30)
    # ...and the new byte has both markers.
    assert _cram(v, 1, 8) == COL_FOCUS, \
        "the new focus cell is colour %d, expected white" % _cram(v, 1, 8)
    assert _cram(v, 1, 31) == COL_MIRROR, \
        "the new companion cell is colour %d, expected light grey" % _cram(v, 1, 31)

    # In the character pane the companion is the byte's TWO hex digits.
    _keys(v, [TAB])
    v.run_for(0.3)
    assert _cram(v, 1, 31) == COL_FOCUS, \
        "after TAB the character cell should be the focus, got %d" % _cram(v, 1, 31)
    assert _cram(v, 1, 8) == COL_MIRROR and _cram(v, 1, 9) == COL_MIRROR, \
        "both hex digits of the byte should be the companion, got %d/%d" \
        % (_cram(v, 1, 8), _cram(v, 1, 9))

    _close_hex(v)


COL_EDITED = 0x07                       # yellow


def test_hex_marks_edited_bytes_in_yellow(v):
    """An edited byte turns yellow in BOTH panes, and stays yellow.

    Two interactions carry the risk, and neither is obvious from reading the
    feature in isolation:

      - cursor_off restores a cell's colour when the cursor leaves. It must
        restore the BYTE's colour, not the pane's, or editing a byte and moving
        on wipes the mark you just made.
      - a cursor move does not repaint (v0.2.13) but a SCROLL does, and the
        repaint's only record of what was edited is the bitmap. Colour RAM is not
        a record: render_row overwrites it.

    The map itself lives just past the document in the buffer, so it also has to
    survive being adjacent to the data it describes.
    """
    assert _open_hex(v, "readme"), "hex did not open\n%s" % v.screen_text()

    pane = _PANE_COLOR[v.read_byte(0xD021) & 0x0F]

    # Edit byte 1 (not 0: byte 0 is where the cursor starts, and its cells are
    # white/grey from the cursor, which would mask a missing mark).
    _keys(v, [K_RIGHT, K_RIGHT])        # nibble, then on to byte 1
    _keys(v, "ab")                      # both nibbles -> cursor steps to byte 2
    v.run_for(0.4)

    # Byte 1's cells: hex pair at cols 8-9, character at col 31.
    for col in (8, 9, 31):
        assert _cram(v, 1, col) == COL_EDITED, \
            "edited byte's cell at col %d is colour %d, expected yellow -- " \
            "cursor_off restores the PANE colour instead of the byte's" \
            % (col, _cram(v, 1, col))

    # Its neighbours are untouched, so the mark is per byte and not per row.
    for col in (14, 33):                # byte 3: never edited, never focused
        assert _cram(v, 1, col) == pane, \
            "an unedited byte at col %d went colour %d, expected the pane's %d" \
            % (col, _cram(v, 1, col), pane)

    # Now the case that isolates cursor_off. Land the cursor back ON the edited
    # byte and then walk off it with plain cursor keys: no edit happens, so
    # nothing repaints the row, and cursor_off's restore is the ONLY thing that
    # decides what colour the byte is left in. (Right after an edit this is
    # invisible -- render_row rebuilds that row from the map and covers a wrong
    # restore, which is why the check above cannot stand in for this one.)
    _keys(v, [K_LEFT])                  # back onto byte 1 (cursor paints it white)
    v.run_for(0.3)
    assert _cram(v, 1, 9) == COL_FOCUS, \
        "expected the cursor back on byte 1, got colour %d" % _cram(v, 1, 9)
    _keys(v, [K_RIGHT, K_RIGHT])        # ...and off it again, editing nothing
    v.run_for(0.3)
    for col in (8, 9, 31):
        assert _cram(v, 1, col) == COL_EDITED, \
            "walking off the edited byte left col %d colour %d -- cursor_off " \
            "restores the pane colour instead of the byte's" \
            % (col, _cram(v, 1, col))

    # The mark must survive a repaint that rebuilds the row from the map.
    assert v.read_memory(0x0800 + 1, 1)[0] == 0xAB, "the edit did not land"
    _keys(v, [K_HOME])                  # forces a full render()
    v.run_for(0.4)
    for col in (8, 9, 31):
        assert _cram(v, 1, col) == COL_EDITED, \
            "the mark at col %d was lost on a full repaint (colour %d) -- the " \
            "repaint is not reading the edit map" % (col, _cram(v, 1, col))

    _close_hex(v)
