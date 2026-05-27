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
    _send(v, [CLEAR] + [ord(c) for c in "hello"])
    v.assert_screen_contains("hello")


def test_echo_backspace_erases(v):
    # "ab" then DEL ($14): b is erased, leaving 'a' then a space. 'a' is
    # ASCII $61 -> screen code $01 in the lowercase charset. The cursor now
    # sits on the cleared cell as a reverse-video block, so mask bit 7.
    _send(v, [CLEAR, 0x61, 0x62, 0x14])
    cells = [b & 0x7F for b in v.read_memory(0x0400, 2)]
    assert cells == [0x01, 0x20], "backspace did not erase 'b'"


def test_clear_wipes_screen(v):
    _send(v, [ord(c) for c in "junk"] + [CLEAR])
    assert "junk" not in v.screen_text(), "clear ($93) did not wipe the screen"
