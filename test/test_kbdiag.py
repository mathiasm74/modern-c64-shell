"""The `debug` command: a live view of the raw keyboard matrix (kbdiag.s).

Its own module, because the viewer runs with interrupts off and only exits on a
physical RUN/STOP -- which the harness cannot press (it injects into the keyboard
BUFFER, not the matrix). So it parks the machine, exactly like test_parse_addr's
run_at, and nothing may follow it in the module.

What this can check is the part that rots: that the viewer reads all eight
select lines and renders what it read at the right place. It cannot check a
CLOSED key -- VICE's matrix is only reachable through real key state -- but
all-open is a real assertion: with nothing held, every cell must read open and
every line must report $FF. A transposed grid, a wrong screen address, a bit
walked the wrong way or a broken hex nibble all fail it.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib.overlays import seed_util_bank

GRIDROW = 4                     # must match kbdiag.s
GRIDCOL = 6
CELLGAP = 3
HEXCOL = GRIDCOL + 24
FLAGCOL = GRIDCOL + 28


def _boot(v):
    """Cold-boot to a live prompt, so neither test depends on the other's state.

    The viewer never returns (interrupts off, exits only on a physical RUN/STOP,
    which the harness cannot press), so whichever test ran first left the machine
    parked in it with a grid still on screen. Without this, the second test
    matches that STALE grid and passes or fails for reasons unrelated to what it
    is checking.
    """
    rv = v.read_byte(0xFFFC) | (v.read_byte(0xFFFD) << 8)
    v.run_at(rv, 0.3)
    for _ in range(15):
        if "Ready." in v.screen_text():
            return
        v.run_for(0.2)
    raise AssertionError("the shell never came back up:\n" + v.screen_text())


def _run_debug(v):
    """Type `debug` and return the screen once IT has drawn a grid."""
    v.inject_keys("debug\r")
    for _ in range(25):
        v.run_for(0.2)
        rows = v.screen_rows()
        if "keyboard matrix" in rows[0] and rows[GRIDROW].startswith("pa0"):
            return rows
    raise AssertionError("the matrix view never drew:\n"
                         + "\n".join(v.screen_rows()[:14]))


def test_debug_shows_every_select_line_as_open(v):
    _boot(v)
    seed_util_bank(v)
    rows = _run_debug(v)

    for sel in range(8):
        row = rows[GRIDROW + sel]
        assert row.startswith("pa%d" % sel), \
            "select line %d is labelled %r" % (sel, row[:4])

        # Eight cells, three columns apart. Nothing is held, so all open.
        cells = "".join(row[GRIDCOL + CELLGAP * r] for r in range(8))
        assert cells == "." * 8, \
            "pa%d drew %r, expected 8 open cells (a '*' means a key read as " \
            "CLOSED with nothing pressed -- the bit walk or the address is off)" \
            % (sel, cells)

        # And the raw byte agrees with the cells it was drawn from.
        assert row[HEXCOL:HEXCOL + 2] == "ff", \
            "pa%d reported raw $%s, expected $ff with no key held" \
            % (sel, row[HEXCOL:HEXCOL + 2])

        # No line may be flagged as held from outside. The flag comes from
        # reading $DC00 BACK after driving every select line high: a 6526
        # returns real pin levels even for output pins, so a bit still reading 0
        # is an outside device pulling it down -- a joystick on control port 2,
        # which shares PA0-PA4 with the keyboard columns and was the actual
        # cause of the fault this tool was written for. VICE has no joystick
        # attached here, so every line must come back clean; a readback that
        # does not work at all would light all eight and fail this.
        assert row[FLAGCOL:FLAGCOL + 5].strip() == "", \
            "pa%d is flagged %r with nothing attached -- the $DC00 readback is " \
            "reporting a phantom external pull" % (sel, row[FLAGCOL:FLAGCOL + 5])


def test_debug_names_the_line_an_outside_device_is_holding_low(v):
    """The flag must land on the RIGHT line -- that is the whole diagnosis.

    The real fault was a joystick on control port 2 holding PA4 low, which the
    viewer reports by reading $DC00 back after driving all eight select lines
    high. The harness cannot attach and hold a joystick button, so instead patch
    the readback in the seeded bank image to return $EF (PA4 low, the rest high)
    and confirm the flag appears on pa4 and nowhere else. That exercises the
    tricky part: the flag text is indexed off the screen offset, so an error
    here draws garbage or marks the wrong line -- in front of someone who is
    already lost.

    """
    _boot(v)
    seed_util_bank(v)

    # lda $DC00 / sta $F7  ->  lda #$EF / sta $F7 / nop.
    # The offset has to come from the bank BINARY: $A000 reads as ROM (the
    # shell's own BASIC half), not as the RAM the bank was seeded into.
    probe = bytes([0xAD, 0x00, 0xDC, 0x85, 0xF7])
    img = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "build", "banks", "util_bank.bin"), "rb").read()
    at = img.find(probe)
    assert at >= 0, "the $DC00 readback is gone -- did the probe change?"
    assert img.find(probe, at + 1) < 0, "more than one $DC00 readback in the bank"
    v.write_memory(0xA000 + at, [0xA9, 0xEF, 0x85, 0xF7, 0xEA])

    rows = _run_debug(v)

    for sel in range(8):
        flag = rows[GRIDROW + sel][FLAGCOL:FLAGCOL + 5]
        if sel == 4:
            assert flag == "<held", \
                "pa4 is held low but shows %r" % flag
        else:
            assert flag.strip() == "", \
                "pa%d shows %r, but only pa4 is held" % (sel, flag)
