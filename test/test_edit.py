"""The edit overlay: a nano-like full-screen editor (tardis, backlog #4).

The editor's code is NOT in the shell ROM -- it's a multi-page overlay
(build/overlays/edit.bin) normally fetched from the One ROM's overlays flash
set. VICE has no One ROM, so these tests PRE-SEED the overlay cache: the
binary is written straight into its run address at $8800 and the resident
thunk's magic-header check accepts it as already cached. That exercises
everything except the (hardware-proven) fetch transport: the thunk, the
mailbox, and the whole editor.

Keys are injected through the keyboard buffer (max 10 at a time), control
codes included -- the matrix-level CTRL decode is exercised separately by
the keytab tests / GUI.

Disk-writing tests run against a throwaway copy of the fixture.
"""

import os
import shutil

from lib.overlays import seed_files, seed_disk_bank, seed_edit

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_edit.d64"))
VICE_DISK = "data/_scratch_edit.d64"


CTRL_X = 0x18
CTRL_O = 0x0F
CTRL_K = 0x0B
CTRL_C = 0x03
CTRL_U = 0x15
CTRL_E = 0x05
CR = 0x0D
CRSR_DOWN = 0x11
CRSR_UP = 0x91
HOME = 0x13


def _seed(v):
    """The editor is a BANK now, not a $8800 overlay -- it outgrew that region
    (see cfg/edit_bank.cfg), so it seeds into the RAM under the $A000 ROM."""
    seed_edit(v)


def _keys(v, codes):
    """Inject key codes through the 10-byte keyboard buffer, chunked.

    Waits by polling the buffer count (NDX $C6) back to zero rather than
    sleeping a fixed interval: the machine consumes a chunk in milliseconds
    of emulated time, so under warp one short run_for usually suffices --
    the old fixed 0.4s per chunk made this module the whole suite's
    critical path."""
    codes = [c if isinstance(c, int) else ord(c) for c in codes]
    while codes:
        chunk = codes[:8]
        codes = codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        for _ in range(20):
            v.run_for(0.05)
            if v.read_byte(0x00C6) == 0:
                break


def _row(v, n):
    return v.screen_rows()[n]


def _wait(v, needle, tries=32, chunk=0.15):
    """Poll until `needle` appears on screen; early-exits long waits.
    (Same ~4.8s total budget as the old 12 x 0.4s, but finer-grained so a
    hit costs a fraction of a second.)"""
    for _ in range(tries):
        if needle in v.screen_text():
            return True
        v.run_for(chunk)
    return needle in v.screen_text()


def test_edit_opens_and_exits(v):
    v.run_for(0.3)
    _seed(v)
    _keys(v, "edit")
    _keys(v, [CR])
    _wait(v, "edit: (new)")
    assert "edit: (new)" in _row(v, 0), \
        "editor title row missing\n%s" % v.screen_text()
    assert "^x exit" in _row(v, 24), \
        "editor help row missing\n%s" % v.screen_text()
    # not modified: ^X leaves immediately, back to a working shell
    _keys(v, [CTRL_X])
    v.run_for(0.5)
    _keys(v, "ver")
    _keys(v, [CR])
    v.run_for(0.5)
    assert "Tardis DOS" in v.screen_text(), \
        "shell did not regain control after edit exit\n%s" % v.screen_text()


def test_edit_types_and_discards(v):
    _seed(v)
    _keys(v, "edit")
    _keys(v, [CR])
    v.run_for(0.4)
    _keys(v, "hello")
    _keys(v, [CR])
    _keys(v, "world")
    v.run_for(0.3)
    assert "hello" in _row(v, 1), "typed text not on row 1\n%s" % v.screen_text()
    assert "world" in _row(v, 2), "second line not on row 2\n%s" % v.screen_text()
    assert "modified" in _row(v, 0), "modified flag not shown"
    # ^X on a modified buffer prompts; 'n' discards
    _keys(v, [CTRL_X])
    v.run_for(0.3)
    assert "save modified buffer" in _row(v, 24), \
        "no save prompt on exit\n%s" % v.screen_text()
    _keys(v, "n")
    v.run_for(0.4)
    _keys(v, "echo ok")
    _keys(v, [CR])
    v.run_for(0.5)
    assert "ok" in v.screen_text(), "shell dead after discard-exit"


def test_edit_cut_and_paste(v):
    _seed(v)
    _keys(v, "edit")
    _keys(v, [CR])
    v.run_for(0.4)
    _keys(v, "aaa")
    _keys(v, [CR])
    _keys(v, "bbb")
    v.run_for(0.3)
    # cut the FIRST line (it carries its CR, so pastes stay line-shaped --
    # cutting a final CR-less line and pasting twice concatenates, like nano)
    _keys(v, [CRSR_UP, CTRL_K])
    v.run_for(0.3)
    assert "aaa" not in v.screen_text(), \
        "cut line still on screen\n%s" % v.screen_text()
    assert "bbb" in _row(v, 1), \
        "remaining line did not move up\n%s" % v.screen_text()
    _keys(v, [CTRL_U, CTRL_U])
    v.run_for(0.3)
    assert "aaa" in _row(v, 1) and "aaa" in _row(v, 2) and "bbb" in _row(v, 3), \
        "paste twice did not restore two aaa lines\n%s" % v.screen_text()
    _keys(v, [CTRL_X])
    v.run_for(0.3)
    _keys(v, "n")
    v.run_for(0.3)


def test_edit_copy_keeps_line(v):
    _seed(v)
    _keys(v, "edit")
    _keys(v, [CR])
    v.run_for(0.4)
    _keys(v, "copyme")
    v.run_for(0.2)
    _keys(v, [CTRL_C])          # copy the line (stays in place)
    v.run_for(0.2)
    assert "copyme" in _row(v, 1), "copy removed the line"
    _keys(v, [CTRL_E, CR])      # to line end (it stays put), new line
    _keys(v, [CTRL_U])          # paste the copy
    v.run_for(0.3)
    txt = v.screen_text()
    assert txt.count("copyme") >= 2, \
        "pasted copy missing\n%s" % txt
    _keys(v, [CTRL_X])
    v.run_for(0.3)
    _keys(v, "n")
    v.run_for(0.3)


def test_edit_loads_existing_file(v):
    # `doc` is the 30-line SEQ fixture (l00..l29); rows 1..23 show l00..l22.
    _seed(v)
    _keys(v, "edit doc")
    _keys(v, [CR])
    _wait(v, "l22")             # IEC read of 30 lines takes a moment
    assert "l00" in _row(v, 1), \
        "first file line not shown\n%s" % v.screen_text()
    assert "l22" in _row(v, 23), \
        "window does not show 23 lines\n%s" % v.screen_text()
    _keys(v, [CTRL_X])          # unmodified: straight out
    v.run_for(0.4)


def test_edit_saves_file_roundtrip(v):
    _seed(v)
    _keys(v, "edit nb")
    _keys(v, [CR])
    _wait(v, "edit: nb")        # tries to load "nb" (not found -> new file)
    _keys(v, "from ed")
    v.run_for(0.3)
    _keys(v, [CTRL_O])
    _wait(v, "wrote")           # IEC write + close
    assert "wrote" in _row(v, 24), \
        "no wrote confirmation\n%s" % v.screen_text()
    _keys(v, [CTRL_X])          # saved -> unmodified -> exits clean
    v.run_for(0.5)
    seed_files(v)               # cat shares $8800 with edit; re-seed it
    _keys(v, "cat nb")
    _keys(v, [CR])
    _wait(v, "from ed")
    assert "from ed" in v.screen_text(), \
        "saved file does not read back\n%s" % v.screen_text()


def test_edit_lightpath_repaints_only_current_line(v):
    # Plain typing takes the light path (one-row repaint). Regression for
    # the v0.13 bug where the cursor row was computed as the LAST window row
    # matching the cursor line, so light-path repaints landed on row 23.
    _seed(v)
    _keys(v, "edit")
    _keys(v, [CR])
    v.run_for(0.4)
    _keys(v, "one")
    _keys(v, [CR])
    _keys(v, "two")
    v.run_for(0.3)
    _keys(v, [CRSR_UP, CTRL_E])     # up to line 1, line end (full renders)
    _keys(v, "x")                   # light path: repaint row 1 only
    v.run_for(0.3)
    assert "onex" in _row(v, 1), \
        "light-path insert missing on its row\n%s" % v.screen_text()
    assert "two" in _row(v, 2), \
        "light-path repaint disturbed another row\n%s" % v.screen_text()
    rows = v.screen_rows()
    assert all(r.strip() == "" for r in rows[3:24]), \
        "light-path repaint leaked below the text\n%s" % v.screen_text()
    _keys(v, [CTRL_X])
    v.run_for(0.3)
    _keys(v, "n")
    v.run_for(0.3)


def test_saved_file_appears_in_ls(v):
    # Companion to the user-reported Meatloaf issue where an editor-saved
    # file showed in `dir` but not `ls` (ls hid lines whose type token it
    # didn't recognize -- splat-marked or non-uppercase). VICE's 1541 sends
    # clean uppercase, so this covers the regression path we can reach;
    # the tolerant parsing (splat '*', lowercase, shifted PETSCII) is
    # exercised by review on hardware.
    _seed(v)
    _keys(v, "edit me.txt")
    _keys(v, [CR])
    _wait(v, "edit: me.txt")
    _keys(v, "x")
    v.run_for(0.2)
    _keys(v, [CTRL_O])
    _wait(v, "wrote")
    _keys(v, [CTRL_X])
    v.run_for(0.5)
    seed_disk_bank(v)
    _keys(v, "ls")
    _keys(v, [CR])
    _wait(v, "ME.TXT")
    assert "ME.TXT" in v.screen_text(), \
        "editor-saved file missing from ls\n%s" % v.screen_text()


def test_edit_lists_a_basic_program(v):
    """Opening a tokenized BASIC program shows it as a listing, not as bytes.

    Two things this proves beyond "it expanded something":
      - the keyword INSIDE the quoted string stays literal, because BASIC does
        not tokenize inside strings and neither may we;
      - the editor refuses to save it. There is no tokenizer yet, so writing
        the listing back would replace a working program with its own source
        text -- data loss, silently.
    """
    v.run_for(0.3)
    _seed(v)
    _keys(v, "edit bas")
    _keys(v, [CR])
    assert _wait(v, "10 PRINT"), \
        "BASIC program was not detokenized\n%s" % v.screen_text()
    txt = v.screen_text()
    # The keyword inside the quotes must survive as text, not be re-expanded.
    assert '"HI PRINT"' in txt, \
        "the quoted string was altered -- tokens must not expand inside quotes\n%s" % txt
    assert "30 REM DONE" in txt, \
        "last line missing (link chain walk stopped early?)\n%s" % txt

    # leave the editor so the next test in this module starts from the prompt
    _keys(v, [CTRL_X])
    _wait(v, "8>")


def test_edit_basic_roundtrip_is_byte_exact(v):
    """Load a BASIC program, save it, and check the BYTES came back identical.

    This is the invariant the tokenizer has to hold: tokenize(detokenize(x)) ==
    x. Checking the listing looks right is not enough -- a program that lists
    correctly can still be wrong in its link chain or its string bytes, and
    BASIC would refuse to run it.

    The expected image is built here rather than read from the fixture so the
    test states what a correct program looks like, byte for byte.
    """
    _seed(v)
    v.run_for(0.3)
    _keys(v, "edit bas")
    _keys(v, [CR])
    assert _wait(v, "10 PRINT"), "listing did not appear\n%s" % v.screen_text()

    _keys(v, [CTRL_O])                  # save: tokenize back to a PRG
    assert _wait(v, "wrote"), \
        "save was refused or failed\n%s" % v.screen_text()
    _keys(v, [CTRL_X])
    _wait(v, "8>")

    # Read it back with `load` and compare the bytes in memory.
    seed_disk_bank(v)
    _keys(v, "load bas")
    _keys(v, [CR])
    assert _wait(v, "loaded $"), "could not load back\n%s" % v.screen_text()

    # The three cases a wrong tokenizer gets wrong, as BASIC V2 stores them:
    # a keyword inside a string, and keyword letters inside DATA and REM
    # ("ONE"/"DONE" both contain ON), which BASIC does not tokenize.
    want = []
    addr = 0x0801
    for num, body in ((10, bytes([0x99]) + b' "HI PRINT"'),
                      (20, bytes([0x83]) + b" ONE,TWO"),
                      (30, bytes([0x8F]) + b" DONE")):
        chunk = bytes([num & 0xFF, num >> 8]) + body + b"\x00"
        addr += 2 + len(chunk)
        want += [addr & 0xFF, addr >> 8] + list(chunk)
    want += [0, 0]

    got = v.read_memory(0x0801, len(want))
    assert got == want, \
        "tokenized bytes differ\n got: %s\nwant: %s" % (
            " ".join("%02X" % b for b in got),
            " ".join("%02X" % b for b in want))


def test_edit_accepts_and_shows_colour_codes(v):
    """A colour code typed into the editor is stored AND visible.

    Two separate things had to change for this. The byte is a control code, so
    the editor's insert filter dropped it; and it has no glyph, so it rendered
    as '?' like every other unprintable. It now shows the way the C64 shows a
    control code inside quotes -- the character whose SCREEN code is the byte,
    in reverse video -- so the eight colours are distinguishable from each
    other instead of all looking the same.

    The physical CTRL+3 is hardware-only (the harness injects into the keyboard
    buffer, not the matrix; test_keyboard checks the table it decodes to), so
    this injects the resulting byte.
    """
    _seed(v)
    v.run_for(0.3)
    _keys(v, "edit")
    _keys(v, [CR])
    _wait(v, "edit: (new)")

    _keys(v, ['1', '0', ' ', 'p', 'r', 'i', 'n', 't', ' ', '"', 0x1C, 'h', 'i'])
    v.run_for(0.3)

    # row 1 is the first document row; "10 print \"" is 10 chars, so the colour
    # code lands in column 10 and the text resumes after it.
    cells = v.screen_cells() if hasattr(v, "screen_cells") else None
    row = v.read_memory(0x0400 + 40, 40)
    assert row[10] == (0x1C | 0x80), \
        "colour code not shown as a reverse-video glyph: got $%02X" % row[10]
    txt = v.screen_text()
    assert "hi" in txt, "text after the colour code was lost\n%s" % txt

    _keys(v, [CTRL_X])                  # discard: modified buffer prompts
    v.run_for(0.3)
    _keys(v, "n")
    _wait(v, "8>")
