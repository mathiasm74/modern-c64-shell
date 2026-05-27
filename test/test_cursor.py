"""The text cursor: a static (non-blinking) reverse-video block, white text.

The cursor is the cell at PNT ($D1/$D2) + PNTR ($D3) shown in reverse video --
bit 7 of its screen code. With white text ($01) on the blue screen, reverse
video reads as a solid white block, and any character under it as blue (the
background colour). CHROUT moves it; there is no timer, so it never blinks.

(`screen_text()` masks bit 7, so the block is invisible to text assertions;
these read the screen codes and colour RAM directly.)
"""


def _cursor_cell(v):
    lo, hi, col = v.read_byte(0xD1), v.read_byte(0xD2), v.read_byte(0xD3)
    return ((hi << 8) | lo) + col


def _color_ram(cell):
    return cell - 0x0400 + 0xD800


def test_cursor_follows_typing(v):
    # Typing 'a' leaves a normal (non-reversed) character and moves the block
    # one cell right.
    v.write_memory(0x0277, [ord("a")])
    v.write_byte(0x00C6, 1)
    v.run_for(0.3)
    cur = _cursor_cell(v)
    assert v.read_byte(cur) & 0x80, "cursor is not a reverse-video block after typing"
    assert not (v.read_byte(cur - 1) & 0x80), "the typed character should not be reversed"
    v.write_memory(0x0277, [0x0D])      # submit, leaving readline clean
    v.write_byte(0x00C6, 1)
    v.run_for(0.3)


def test_cursor_is_static_block(v):
    cur = _cursor_cell(v)
    assert v.read_byte(cur) & 0x80, "cursor cell is not a reverse-video block"
    # With no input the cursor must not move or blink off.
    seen = []
    for _ in range(5):
        v.run_for(0.15)
        seen.append(v.read_byte(_cursor_cell(v)) >> 7)
    assert all(seen), "cursor blinked off; it should be static: %r" % seen


def test_text_and_cursor_are_white(v):
    cur = _cursor_cell(v)
    lo, hi = v.read_byte(0xD1), v.read_byte(0xD2)
    line_start = (hi << 8) | lo
    assert (v.read_byte(_color_ram(cur)) & 0x0F) == 0x01, "cursor colour is not white"
    assert (v.read_byte(_color_ram(line_start)) & 0x0F) == 0x01, "text colour is not white"
