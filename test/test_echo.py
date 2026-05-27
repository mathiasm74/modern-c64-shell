"""Interactive I/O: the timer IRQ runs, and keystrokes echo to the screen.

These drive the full GETIN -> echo loop -> CHROUT pipeline by writing the
keyboard buffer directly (the keyboard matrix scan itself can only be checked
by typing in the GUI). Each test starts by sending a clear ($93) so it begins
from a known screen with the cursor homed, independent of earlier tests.
"""

CLEAR = 0x93


def _send(v, codes):
    """Place raw PETSCII codes in the keyboard buffer and let the ROM run."""
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def test_jiffy_clock_advances(v):
    before = v.read_memory(0xA0, 3)
    v.run_for(0.2)
    after = v.read_memory(0xA0, 3)
    assert after != before, \
        "jiffy clock $A0-$A2 did not advance (timer IRQ not firing): %r" % after


def test_echo_typed_text(v):
    _send(v, [CLEAR] + [ord(c) for c in "HELLO"])
    v.assert_screen_contains("HELLO")


def test_echo_return_starts_new_line(v):
    # "AB", RETURN, "CD" -> AB on row 0, CD on row 1.
    _send(v, [CLEAR, 0x41, 0x42, 0x0D, 0x43, 0x44])
    assert v.read_memory(0x0400, 2) == [0x01, 0x02], "row 0 should read 'AB'"
    assert v.read_memory(0x0400 + 40, 2) == [0x03, 0x04], "row 1 should read 'CD'"


def test_echo_backspace_erases(v):
    # "AB" then DEL ($14): B is erased, leaving 'A' then a space.
    _send(v, [CLEAR, 0x41, 0x42, 0x14])
    assert v.read_memory(0x0400, 2) == [0x01, 0x20], "backspace did not erase 'B'"


def test_clear_wipes_screen(v):
    _send(v, [ord(c) for c in "JUNK"] + [CLEAR])
    assert "JUNK" not in v.screen_text(), "clear ($93) did not wipe the screen"


def test_scroll_lifts_content(v):
    # Put 'Z' on row 1, then send 24 RETURNs. The cursor walks to the bottom
    # and one more newline scrolls the whole screen up by one, lifting 'Z'
    # from row 1 to row 0. ($5A 'Z' -> screen code $1A.)
    _send(v, [CLEAR, 0x0D, 0x5A])      # clear, newline to row 1, type Z
    _send(v, [0x0D] * 10)              # 24 newlines total, in buffer-sized
    _send(v, [0x0D] * 10)              # batches (the buffer holds 10)
    _send(v, [0x0D] * 4)
    assert v.read_byte(0x0400) == 0x1A, \
        "expected 'Z' lifted to row 0 by scrolling, got $%02X" % v.read_byte(0x0400)
