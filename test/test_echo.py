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
    # Reset via the `clear` COMMAND (the CLR keystroke only wipes the input
    # line since v0.1.57): the fresh prompt "8> " lands at row 0, so the
    # typed text starts at column 3.
    _send(v, [ord(c) for c in "clear"] + [0x0D, 0x61, 0x62, 0x14])
    for _ in range(20):                 # ride out warp starvation in parallel runs
        if v.read_byte(0x00C6) == 0:
            break
        v.run_for(0.2)
    v.run_for(0.2)                      # let the last echo land
    cells = [b & 0x7F for b in v.read_memory(0x0400 + 3, 2)]
    assert cells == [0x01, 0x20], "backspace did not erase 'b'"


def test_clr_wipes_input_line_not_screen(v):
    # Since v0.1.57 CLR at the prompt wipes only the pending input: "junk"
    # vanishes from the line, but the boot banner survives (the old behavior
    # -- a full screen clear -- would have taken it too).
    _send(v, [ord(c) for c in "junk"] + [CLEAR])
    assert "junk" not in v.screen_text(), "CLR did not wipe the typed input"
    assert "Tardis DOS" in v.screen_text(), "CLR cleared the whole screen"
