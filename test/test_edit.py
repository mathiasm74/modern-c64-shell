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
CTRL_D = 0x04           # ^M is RETURN, ^T is DEL; ^D is free
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


def test_edit_legend_fits_the_row_and_lists_ctrl_d(v):
    """The help row is exactly COLS wide and put_str does not clip, so an
    over-long legend writes past the end of screen RAM -- and its last entry
    is unreadable. The previous one was 41 characters and displayed as
    "^v litera".
    """
    _seed(v)
    _keys(v, "edit")
    _keys(v, [CR])
    _wait(v, "edit: (new)")
    legend = _row(v, 24)
    assert "^d mode" in legend, \
        "^D is missing from the legend\n%s" % v.screen_text()
    # Nothing spilled past the row: the cell after the last screen cell is
    # untouched by the legend (screen RAM is 1000 cells, $0400-$07E7).
    assert legend.rstrip() == legend.rstrip().strip(), "legend padding odd"
    assert len(legend.rstrip()) <= 40, \
        "legend is wider than the row: %r" % legend
    _keys(v, [CTRL_X])
    _wait(v, "8>")


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


def _cursor_cell(v):
    """(row, col) of the editor's inverted cursor cell, searching the text
    window only (the title/help rows are never reversed)."""
    cells = v.screen_cells()
    for i in range(40, 24 * 40):
        if cells[i] & 0x80:
            return divmod(i, 40)
    return None


def test_edit_cursor_follows_typing_on_the_last_line(v):
    # Regression: row_start() walked PAST the row when the cursor sat at the
    # end of a line that ends the document without a CR -- the everyday case
    # of typing into a new file. The character landed correctly but the
    # cursor was drawn at column 0 of the row BELOW it.
    _seed(v)
    _keys(v, "edit")
    _keys(v, [CR])
    _wait(v, "edit: (new)")
    assert _cursor_cell(v) == (1, 0), \
        "cursor not at the start of an empty document\n%s" % v.screen_text()
    _keys(v, "hello")
    v.run_for(0.3)
    assert "hello" in _row(v, 1), "typed text missing\n%s" % v.screen_text()
    assert _cursor_cell(v) == (1, 5), \
        "cursor not after the typed text\n%s" % v.screen_text()
    _keys(v, [CTRL_X])
    v.run_for(0.3)
    _keys(v, "n")
    v.run_for(0.3)


def test_edit_typing_on_the_last_line_takes_the_light_path(v):
    # Same bug's other half: because row_start(gs) never matched cur_ls, every
    # keystroke on the last line fell through to the full 23-row redraw, which
    # is what made the editor flicker and feel slow. Detect it by planting a
    # marker in an untouched window row -- a full redraw wipes it, the
    # one-row light path does not.
    _seed(v)
    _keys(v, "edit")
    _keys(v, [CR])
    _wait(v, "edit: (new)")
    _keys(v, "ab")
    v.run_for(0.3)
    v.write_memory(0x0400 + 5 * 40, [0x17, 0x13, 0x0A])      # "wsj" on row 5
    _keys(v, "c")
    v.run_for(0.3)
    assert "abc" in _row(v, 1), "typed text missing\n%s" % v.screen_text()
    assert list(v.read_memory(0x0400 + 5 * 40, 3)) == [0x17, 0x13, 0x0A], \
        "a full redraw wiped the marker row: typing took the heavy path\n%s" \
        % v.screen_text()
    _keys(v, [CTRL_X])
    v.run_for(0.3)
    _keys(v, "n")
    v.run_for(0.3)


def test_edit_save_on_exit_returns_to_the_shell(v):
    # Every other exit test answers 'n'. The 'y' path -- save, then leave --
    # had no coverage at all, and it is the one that can fail: save_file()
    # returning 0 keeps the editor open, which is right, but it must not
    # happen on a good save.
    _seed(v)
    _keys(v, "edit sv")
    _keys(v, [CR])
    _wait(v, "edit: sv")
    _keys(v, "hi there")
    v.run_for(0.3)
    _keys(v, [CTRL_X])
    v.run_for(0.4)
    assert "save modified buffer" in _row(v, 24), \
        "no save prompt on exit\n%s" % v.screen_text()
    _keys(v, "y")
    assert _wait(v, "8>"), \
        "editor did not exit after saving\n%s" % v.screen_text()
    # and the shell is alive, not just showing a stale prompt
    _keys(v, "ver")
    _keys(v, [CR])
    v.run_for(0.5)
    assert "Tardis DOS" in v.screen_text(), \
        "shell dead after save-and-exit\n%s" % v.screen_text()


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
      - it round-trips: test_edit_basic_roundtrip_is_byte_exact saves it back
        out through the tokenizer and compares the bytes. (This docstring used
        to say the editor refused to save a listing, which stopped being true
        when the tokenizer landed in v0.2.04.)
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


def test_edit_basic_status_does_not_claim_read_only(v):
    """The status line said "basic (read-only)" long after the tokenizer made
    saving work -- so it told you the opposite of the truth, on a file the
    round-trip test proves is writable."""
    _seed(v)
    _keys(v, "edit bas")
    _keys(v, [CR])
    assert _wait(v, "10 PRINT"), \
        "BASIC program was not detokenized\n%s" % v.screen_text()
    assert "read-only" not in _row(v, 24), \
        "status still claims a BASIC listing is read-only\n%s" % v.screen_text()
    assert "basic" in _row(v, 24), \
        "status no longer says the file is BASIC\n%s" % v.screen_text()
    _keys(v, [CTRL_X])
    _wait(v, "8>")


def test_edit_ctrl_d_makes_a_new_document_a_basic_program(v):
    """^D chooses what the document IS, so a program can be WRITTEN, not only
    edited. basic_mode was set by load_file alone, so a listing typed into a
    new file could only ever be saved as SEQ text -- there was no way to
    create a BASIC program with the editor at all.

    Checks the drive's own verdict: type is PRG and the saved length is the
    TOKENIZED size, not the 10 characters that were typed.
    """
    _seed(v)
    _keys(v, "edit pg")
    _keys(v, [CR])
    _wait(v, "edit: pg")
    assert "text" in _row(v, 0), \
        "a new document should start as text\n%s" % v.screen_text()
    _keys(v, "10 print 1")
    v.run_for(0.3)
    _keys(v, [CTRL_D])
    v.run_for(0.4)
    assert "basic" in _row(v, 0), \
        "^D did not switch the document to basic\n%s" % v.screen_text()
    _keys(v, [CTRL_O])                      # save
    assert _wait(v, "wrote"), "save did not report\n%s" % v.screen_text()
    # 10 characters typed; tokenized it is shorter, plus the $0801 load address
    assert "wrote 12" in _row(v, 24), \
        "saved size is not the tokenized one\n%s" % v.screen_text()
    _keys(v, [CTRL_X])                      # saved, so it leaves without asking
    _wait(v, "8>")
    # Re-open it: only a TOKENIZED program at $0801 makes load_file's sniff
    # come back in basic mode and detokenize. That proves what was written
    # without seeding the disk bank -- a bank swap mid-module leaves the edit
    # bank unseeded for every test that follows if its wait ever expires.
    _keys(v, "edit pg")
    _keys(v, [CR])
    assert _wait(v, "10 PRINT"), \
        "saved file did not come back as a listing\n%s" % v.screen_text()
    assert "basic" in _row(v, 0), \
        "saved file was not recognised as a basic program\n%s" % v.screen_text()
    _keys(v, [CTRL_X])
    _wait(v, "8>")


def test_edit_ctrl_d_toggles_back_to_text(v):
    """The switch works both ways: a loaded BASIC program can be saved as its
    listing, which is also what makes ^D safe to press by mistake."""
    _seed(v)
    _keys(v, "edit bas")
    _keys(v, [CR])
    assert _wait(v, "10 PRINT"), "listing missing\n%s" % v.screen_text()
    assert "basic" in _row(v, 0), \
        "a loaded program should start in basic mode\n%s" % v.screen_text()
    _keys(v, [CTRL_D])
    v.run_for(0.4)
    assert "text" in _row(v, 0), \
        "^D did not switch the program to text\n%s" % v.screen_text()
    # ^D alone does not dirty the buffer -- it changes how a future save is
    # written, not the text -- so ^X leaves without asking.
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


def test_edit_wraps_long_lines(v):
    """A line longer than the window continues on the next row.

    BASIC lines run to 80 characters, so without wrapping the right-hand half
    of a listing is simply invisible and the cursor sticks against column 39.
    Display rows now break at the window width as well as at a CR.
    """
    _seed(v)
    v.run_for(0.3)
    _keys(v, "edit")
    _keys(v, [CR])
    _wait(v, "edit: (new)")

    # 50 characters: 40 on the first row, 10 on the second.
    _keys(v, "abcdefghij" * 5)
    v.run_for(0.4)

    row1 = v.read_memory(0x0400 + 40, 40)       # first document row
    row2 = v.read_memory(0x0400 + 80, 40)       # its continuation
    assert row1[39] != 0x20, "first row is not full -- did it wrap early?"
    assert row2[0] != 0x20, \
        "long line did not continue on the next row (truncated at 40?)"
    # Mask the reverse-video bit: the cursor now correctly rests ON the
    # continuation row at column 10 (a reversed space), rather than a row
    # lower. What this asserts is that no 11th CHARACTER wrapped down.
    assert row2[9] != 0x20 and row2[10] & 0x7F == 0x20, \
        "continuation row holds the wrong number of characters"

    _keys(v, [CTRL_X])
    v.run_for(0.3)
    _keys(v, "n")
    _wait(v, "8>")


def test_edit_literal_next_inserts_a_bound_key(v):
    """^V inserts the next key as text, even one the editor binds.

    PETSCII white is $05, which IS ^E -- the line-end binding eats it, so
    CTRL+2 can never reach the text on its own. The same clash waits for every
    control code an editor binds (cursor down $11, home $13, clear $93), all of
    which are legal inside a BASIC string. One escape key settles the class.
    """
    _seed(v)
    v.run_for(0.3)
    _keys(v, "edit")
    _keys(v, [CR])
    _wait(v, "edit: (new)")

    _keys(v, [0x16, 0x05])              # ^V then white
    v.run_for(0.4)
    row = v.read_memory(0x0400 + 40, 40)
    assert row[0] == (0x05 | 0x80), \
        "^V did not insert the bound key as text: got $%02X" % row[0]

    _keys(v, [CTRL_X])
    v.run_for(0.3)
    _keys(v, "n")
    _wait(v, "8>")


def test_edit_accepts_petscii_graphics(v):
    """The editor stores and draws the PETSCII graphics set (C= + key).

    They are the characters BASIC programs draw boxes and bars with, so an
    editor that dropped them could not hold a real listing. $A0-$FF map to
    screen codes the same way pet2scr does it.
    """
    _seed(v)
    v.run_for(0.3)
    _keys(v, "edit")
    _keys(v, [CR])
    _wait(v, "edit: (new)")

    _keys(v, [0xA0, 0xA1, 0xDB, 0xFF])
    v.run_for(0.4)
    row = v.read_memory(0x0400 + 40, 4)
    assert row == [0x60, 0x61, 0x5B, 0x7F], \
        "graphics not stored/drawn: %s" % [hex(b) for b in row]

    _keys(v, [CTRL_X])
    v.run_for(0.3)
    _keys(v, "n")
    _wait(v, "8>")
