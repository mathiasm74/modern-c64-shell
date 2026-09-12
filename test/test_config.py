"""Appearance commands: border / bg / text colors.

border/bg poke the VIC registers ($D020/$D021) and text sets the KERNAL text
color ($0286). All three live in the files overlay (cmds 8-10) -- the bodies
cost overlay flash, not the 16KB ROM -- so the tests seed that overlay first.
No disk needed (these never touch the drive).
"""

from lib.overlays import seed_files, seed_picker

CR = 0x0D


def _ch(s):
    return [ord(c) for c in s]


def _run(v, text):
    seed_files(v)
    v.write_memory(0x0277, _ch(text) + [CR])
    v.write_byte(0x00C6, len(text) + 1)
    v.run_for(0.4)


def test_border_color(v):
    _run(v, "border 2")
    for _ in range(6):
        if (v.read_byte(0xD020) & 0x0F) == 2:
            break
        v.run_for(0.3)
    assert (v.read_byte(0xD020) & 0x0F) == 2, "border color not set"


def test_background_color(v):
    v.write_byte(0xD021, 0x0F)               # set non-zero first, so 0 is a real change
    _run(v, "bg 0")
    for _ in range(6):
        if (v.read_byte(0xD021) & 0x0F) == 0:
            break
        v.run_for(0.3)
    assert (v.read_byte(0xD021) & 0x0F) == 0, "background color not set"


def test_text_color(v):
    _run(v, "text 7")
    for _ in range(6):
        if (v.read_byte(0x0286) & 0x0F) == 7:
            break
        v.run_for(0.3)
    assert (v.read_byte(0x0286) & 0x0F) == 7, "text color not set"


def _open_picker(v, cmd):
    """Seed the picker overlay, type a no-value color command, wait for it."""
    seed_picker(v)
    v.write_memory(0x0277, _ch(cmd) + [CR])
    v.write_byte(0x00C6, len(cmd) + 1)
    for _ in range(12):
        v.run_for(0.3)
        if "color" in v.screen_text():
            return True
    return False


def _send_keys(v, keys):
    v.write_memory(0x0277, keys)
    v.write_byte(0x00C6, len(keys))
    for _ in range(8):
        v.run_for(0.3)
        if "color" not in v.screen_text():     # picker cleared the screen
            return


def test_bg_picker_moves_and_sets(v):
    # `bg` with no value opens the resident color picker: 16 solid blocks ($A0
    # at col 4) and an 'o' marker. Right twice then RETURN advances the color
    # by 2 and keeps it. (No overlay seed: the picker is resident.)
    start = v.read_byte(0xD021) & 0x0F
    assert _open_picker(v, "bg"), "bg picker did not appear\n%s" % v.screen_text()
    assert v.read_byte(0x0400 + 6 * 40 + 4) == 0xA0, "color blocks not drawn"
    _send_keys(v, [0x1D, 0x1D, CR])            # right, right, RETURN
    assert (v.read_byte(0xD021) & 0x0F) == ((start + 2) & 0x0F), \
        "bg should advance by 2 from %d" % start


def test_picker_stop_reverts(v):
    orig = v.read_byte(0xD021) & 0x0F
    assert _open_picker(v, "bg"), "bg picker did not appear"
    _send_keys(v, [0x1D, 0x1D, 0x03])          # right, right, STOP -> revert
    assert (v.read_byte(0xD021) & 0x0F) == orig, \
        "STOP should revert bg to %d, got %d" % (orig, v.read_byte(0xD021) & 0x0F)


def test_picker_down_moves_left(v):
    # Down does the same as left (previous color), so down/right navigate
    # without shifting. Two downs move the color back by 2.
    start = v.read_byte(0xD021) & 0x0F
    assert _open_picker(v, "bg"), "bg picker did not appear"
    _send_keys(v, [0x11, 0x11, CR])            # down, down, RETURN
    assert (v.read_byte(0xD021) & 0x0F) == ((start - 2) & 0x0F), \
        "down should move back by 2 from %d" % start




def test_text_picker_previews_on_screen(v):
    """Stepping the text colour must actually recolour what is on screen.

    border and bg are single VIC registers, so previewing them is one write and
    the whole screen follows. $0286 is not: it only decides the colour of
    characters drawn from then on, so the picker set it and the already-drawn
    text stayed white -- there was no preview at all (hardware-reported). The fix
    repaints colour RAM, which means the swatches have to be redrawn after it;
    this checks both halves, since a repaint that ate the swatches would leave
    the user choosing from 16 identical blocks.
    """
    assert _open_picker(v, "text"), \
        "text picker did not appear\n%s" % v.screen_text()

    # The title is on row 0, drawn before any preview -- so it is exactly the
    # text that used to stay white.
    title_cell = 0xD800 + 0                     # colour of the first title char
    before = v.read_byte(title_cell) & 0x0F

    v.write_memory(0x0277, [0x1D, 0x1D])        # right, right: +2 colours
    v.write_byte(0x00C6, 2)
    for _ in range(8):
        v.run_for(0.3)
        if (v.read_byte(title_cell) & 0x0F) != before:
            break

    after = v.read_byte(title_cell) & 0x0F
    assert after != before, \
        "the text on screen did not change colour (still %d) -- $0286 alone " \
        "does not repaint anything already drawn" % before
    assert after == ((before + 2) & 0x0F), \
        "expected the colour two steps on from %d, got %d" % (before, after)

    # The swatches must be untouched: the repaint stops at row 4, which is what
    # keeps them from flickering (they were being redrawn behind it before).
    swatch = 0xD800 + 6 * 40 + 4
    seen = [v.read_byte(swatch + i * 2) & 0x0F for i in range(16)]
    assert seen == list(range(16)), \
        "the preview repaint reached the colour swatches: %s" % seen

    # The title is drawn in REVERSE -- an example of inverted text, and for this
    # picker a second sample of the colour, as the character's background.
    cells = v.read_memory(0x0400, len("text color"))
    assert all(c & 0x80 for c in cells), \
        "the title is not in reverse: %s" % [hex(c) for c in cells]

    _send_keys(v, [0x03])                       # STOP: revert, leave the picker
