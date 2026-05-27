"""Line editing inside readline: cursor movement, mid-line insert and delete.

These inject cursor PETSCII codes -- left ($9D), right ($1D) -- straight into
the keyboard buffer. The editing logic doesn't care that physically typing
cursor-left needs SHIFT (a GUI-only path, still a TODO). What the edited line
buffer ended up holding is proved by the dispatched command, which the shell
echoes back as "Command not found: <text>". A couple of checks read the cursor
column at $D3.

Every test submits its line with RETURN so readline is left clean for the next
test (they share one VICE instance).
"""

LEFT = 0x9D
RIGHT = 0x1D
DEL = 0x14
CR = 0x0D
CLEAR = 0x93


def _send(v, codes):
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.4)


def _ch(s):
    return [ord(c) for c in s]


def test_insert_mid_line(v):
    # "abc", cursor left twice (between a and b), insert 'x' -> "axbc".
    _send(v, [CLEAR] + _ch("abc") + [LEFT, LEFT] + _ch("x") + [CR])
    v.assert_screen_contains("Command not found: axbc")


def test_delete_mid_line(v):
    # "axbc", left twice (between x and b), DELETE removes 'x' -> "abc".
    _send(v, [CLEAR] + _ch("axbc") + [LEFT, LEFT, DEL, CR])
    v.assert_screen_contains("Command not found: abc")
    assert "Command not found: axbc" not in v.screen_text(), \
        "mid-line delete did not remove 'x'"


def test_cursor_right_then_insert(v):
    # "ab", left to the start, right one, insert 'x' -> "axb".
    _send(v, [CLEAR] + _ch("ab") + [LEFT, LEFT, RIGHT] + _ch("x") + [CR])
    v.assert_screen_contains("Command not found: axb")


def test_cursor_left_stops_at_start(v):
    # Extra lefts past the start are ignored; 'x' inserts at the front -> "xab".
    _send(v, [CLEAR] + _ch("ab") + [LEFT, LEFT, LEFT, LEFT] + _ch("x") + [CR])
    v.assert_screen_contains("Command not found: xab")


def test_cursor_right_stops_at_end(v):
    # Extra rights past the end are ignored; 'x' appends -> "abx".
    _send(v, [CLEAR] + _ch("ab") + [RIGHT, RIGHT] + _ch("x") + [CR])
    v.assert_screen_contains("Command not found: abx")


def test_cursor_column_tracks_edits(v):
    # After a clear the input starts at column 0, so the cursor column ($D3)
    # equals the logical position. "abc" then one left -> column 2.
    _send(v, [CLEAR] + _ch("abc") + [LEFT])
    col = v.read_byte(0xD3)
    _send(v, [CR])              # submit, leaving readline clean for later tests
    assert col == 2, "cursor column wrong after left (got %d)" % col
