"""Interactive I/O: the timer IRQ runs, and keystrokes echo to the screen.

These drive the GETIN -> CHROUT pipeline by writing the keyboard buffer
directly (the keyboard matrix scan itself can only be checked by typing in
the GUI). As of Phase 4 the input is consumed by the C shell's readline
rather than a raw echo loop, but readline still echoes each character and
passes control codes straight to CHROUT, so these checks hold unchanged.
Each test starts by sending a clear ($93) so it begins from a known screen
with the cursor homed, independent of earlier tests.

Two former tests here -- that RETURN starts a new line, and that the screen
scrolls -- were echo-loop behaviors that the shell now mediates (RETURN
submits a command). They moved to test_shell.py, expressed against the shell.
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


def test_echo_backspace_erases(v):
    # "AB" then DEL ($14): B is erased, leaving 'A' then a space.
    _send(v, [CLEAR, 0x41, 0x42, 0x14])
    assert v.read_memory(0x0400, 2) == [0x01, 0x20], "backspace did not erase 'B'"


def test_clear_wipes_screen(v):
    _send(v, [ord(c) for c in "JUNK"] + [CLEAR])
    assert "JUNK" not in v.screen_text(), "clear ($93) did not wipe the screen"
