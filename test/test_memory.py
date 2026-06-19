"""Known memory/register values after a clean boot."""


def test_border_is_brown(v):
    border = v.read_byte(0xD020)
    assert border is not None and (border & 0x0F) == 0x09, \
        "border color is $%02X, expected brown ($09)" % (border or 0)


def test_background_is_orange(v):
    bg = v.read_byte(0xD021)
    assert bg is not None and (bg & 0x0F) == 0x08, \
        "background color is $%02X, expected orange ($08)" % (bg or 0)


def test_screen_cleared_below_banner(v):
    # The banner occupies rows 1 and 3; the last row should be blank spaces.
    last_row = v.read_memory(0x0400 + 24 * 40, 40)
    assert all(b == 0x20 for b in last_row), \
        "bottom screen row is not cleared to spaces: %r" % last_row
