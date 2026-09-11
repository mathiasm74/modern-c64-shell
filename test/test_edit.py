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

from lib.overlays import seed_files, seed_disk_bank

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_edit.d64"))
VICE_DISK = "data/_scratch_edit.d64"

_EDIT_BIN = os.path.join(_HERE, "..", "build", "overlays", "edit.bin")

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
    with open(_EDIT_BIN, "rb") as f:
        data = list(f.read())
    v.write_memory(0x8800, data)


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
