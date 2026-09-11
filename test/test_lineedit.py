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

from lib.overlays import seed_util_bank

LEFT = 0x9D
RIGHT = 0x1D
DEL = 0x14
CR = 0x0D
CLEAR = 0x93            # CLR: wipes the pending input (not the screen)
HOME = 0x13             # HOME: to the start of the input (not the screen)
TAB = 0x09              # filename completion (a bare CTRL tap emits this)


def _send(v, codes):
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.4)


def _ch(s):
    return [ord(c) for c in s]


def _fresh_line(v):
    """Reset the screen with the `clear` COMMAND (since v0.1.57 the CLR key
    only wipes the input line) and return the fresh prompt's cursor column,
    so position-sensitive tests can work relative to the prompt width."""
    _send(v, _ch("clear") + [CR])
    return v.read_byte(0xD3)


def _type_n(v, ch, n):
    """Type `n` copies of `ch`, in keyboard-buffer-sized batches."""
    code = ord(ch)
    while n > 0:
        k = min(n, 10)
        v.write_memory(0x0277, [code] * k)
        v.write_byte(0x00C6, k)
        v.run_for(0.2)
        n -= k


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


def test_cursor_left_wraps_past_line_start(v):
    # Fill row 0 so the cursor wraps to row 1, column 0. LEFT must then step
    # back to row 0, column 39 -- the reported bug was it sticking at col 0.
    col = _fresh_line(v)
    _type_n(v, "x", 40 - col)
    assert v.read_byte(0xD6) == 1 and v.read_byte(0xD3) == 0, \
        "40 chars did not wrap to row 1 (TBLX=%d PNTR=%d)" % (
            v.read_byte(0xD6), v.read_byte(0xD3))
    _send(v, [LEFT])
    assert v.read_byte(0xD6) == 0, "cursor left did not move up to the first row"
    assert v.read_byte(0xD3) == 39, "cursor left did not land at column 39"
    _send(v, [CR])


def test_backspace_wraps_past_line_start(v):
    # The DELETE mirror of the cursor-left wrap: fill row 0 so the cursor sits
    # at row 1 col 0, then DELETE must step back to row 0 col 39 AND blank that
    # cell. (Bug: backspace stuck at col 0 -- it dropped the char from the line
    # buffer but left the screen untouched until you arrowed back, after which
    # further deletes acted on characters that looked already gone.)
    col = _fresh_line(v)
    _type_n(v, "x", 40 - col)
    assert v.read_byte(0xD6) == 1 and v.read_byte(0xD3) == 0, \
        "40 chars did not wrap to row 1 (TBLX=%d PNTR=%d)" % (
            v.read_byte(0xD6), v.read_byte(0xD3))
    _send(v, [DEL])
    assert v.read_byte(0xD6) == 0, "backspace did not move up to the first row"
    assert v.read_byte(0xD3) == 39, "backspace did not land at column 39"
    # the erased cell reads as a space (the cursor block sits on it, but
    # screen_rows masks bit 7)
    assert v.screen_rows()[0][39] == " ", \
        "backspace did not erase the character at the wrap boundary"
    _send(v, [CR])


def test_cursor_right_wraps_to_next_line(v):
    # The mirror of the above: from row 0 col 39, RIGHT wraps to row 1 col 0.
    col = _fresh_line(v)
    _type_n(v, "x", 40 - col)
    _send(v, [LEFT])               # row 0, col 39
    _send(v, [RIGHT])              # back to row 1, col 0
    assert v.read_byte(0xD6) == 1 and v.read_byte(0xD3) == 0, \
        "cursor right did not wrap to the next row (TBLX=%d PNTR=%d)" % (
            v.read_byte(0xD6), v.read_byte(0xD3))
    _send(v, [CR])


def test_cursor_column_tracks_edits(v):
    # The cursor column ($D3) tracks the logical position relative to the
    # prompt: "abc" then one left -> prompt column + 2.
    col0 = _fresh_line(v)
    _send(v, _ch("abc") + [LEFT])
    col = v.read_byte(0xD3)
    _send(v, [CR])              # submit, leaving readline clean for later tests
    assert col == col0 + 2, \
        "cursor column wrong after left (got %d, prompt at %d)" % (col, col0)


def test_home_returns_to_input_start(v):
    # HOME ($13) moves to the start of the INPUT (not the screen home): with
    # "bc" typed, HOME then "a" inserts at the front -> "abc". A screen-home
    # would have echoed the 'a' at 0,0 and submitted "bca" instead.
    _send(v, _ch("bc") + [HOME] + _ch("a") + [CR])
    v.assert_screen_contains("Command not found: abc")
    assert "Command not found: bca" not in v.screen_text(), \
        "HOME went to the screen home, not the input start"


def test_clr_wipes_input_not_screen(v):
    # CLR ($93) at the prompt wipes the pending input only: "zap" vanishes,
    # the retyped "ver" runs clean (proving the line buffer really emptied),
    # and earlier prompt rows survive (a full screen clear would leave only
    # the fresh prompt's "8>" on screen).
    _send(v, _ch("zap") + [CLEAR])
    _send(v, _ch("ver") + [CR])
    v.assert_screen_contains("Tardis DOS v")
    assert v.screen_text().count("8>") >= 2, \
        "CLR cleared the whole screen, not just the input line"


# --- filename TAB completion (docs/TAB-COMPLETION.md) -----------------------
# readline completes from the $CE00 name cache that ls/dir fill. Seeding the
# cache directly makes every matching/insertion/listing rule testable with no
# drive attached. (The CTRL-tap -> $09 emission itself is matrix-driven, so
# it is GUI/hardware-verified like SHIFT; these tests inject $09.)

def _seed_tab_cache(v, names):
    """Fill the $CE00 name cache -- and seed the util bank, since completion
    lives there now (docs/ROM-EXPANSION.md). Without the bank, TAB is silently
    inert by design, so every completion assertion would fail."""
    seed_util_bank(v)
    data = [1, len(names)]
    for nm in names:
        data += [len(nm)] + [ord(c) for c in nm.upper()]
    v.write_memory(0xCE00, data)


def test_tab_completes_unique_match(v):
    _seed_tab_cache(v, ["pirates", "doc"])
    _send(v, _ch("zz pi") + [TAB])
    v.assert_screen_contains("zz pirates")
    _send(v, [CLEAR])                    # wipe the line for the next test


def test_tab_completes_common_prefix_then_lists(v):
    _seed_tab_cache(v, ["progone", "progtwo", "doc"])
    _send(v, _ch("zz pr") + [TAB])       # extends to the common prefix
    v.assert_screen_contains("zz prog")
    _send(v, [TAB])                      # no progress -> list candidates
    v.assert_screen_contains("progone")
    v.assert_screen_contains("progtwo")
    # the line is reprinted after the listing, cursor at its end
    rows = [r for r in v.screen_rows() if "zz prog" in r]
    assert len(rows) >= 2, "line was not reprinted after the candidate list"
    _send(v, [CLEAR])


def test_tab_inert_on_first_word(v):
    _seed_tab_cache(v, ["pirates"])
    _send(v, _ch("pi") + [TAB] + _ch("!") + [CR])
    v.assert_screen_contains("Command not found: pi!")


def test_tab_inert_when_cache_invalid(v):
    _seed_tab_cache(v, ["pirates"])
    v.write_byte(0xCE00, 0)              # invalidated
    _send(v, _ch("zz pi") + [TAB] + [CR])
    assert "zz pirates" not in v.screen_text(), \
        "TAB completed from an invalidated cache"


def test_tab_completes_mid_line(v):
    # Completion uses the word up to the CURSOR; text right of it is pushed
    # along: "zz pix" with the cursor before 'x' completes "pi" -> "pirates".
    _seed_tab_cache(v, ["pirates"])
    _send(v, _ch("zz pix") + [LEFT] + [TAB])
    v.assert_screen_contains("zz piratesx")
    _send(v, [CLEAR])


def test_tab_completes_past_first_cache_page(v):
    # A networked (Meatloaf) folder can list 40+ names -- more than one page
    # of packed entries. The cache spans $CE00-$CFFF and the walk offsets are
    # 16-bit; completing the LAST of 30 long names exercises entries past
    # offset 256, which the original one-page cache silently dropped.
    names = ["entry%02dxxxxx" % i for i in range(29)] + ["zebrafile"]
    _seed_tab_cache(v, names)
    _send(v, _ch("zz ze") + [TAB])
    v.assert_screen_contains("zz zebrafile")
    _send(v, [CLEAR])


def test_tab_autoquotes_spaced_names(v):
    # Completing a spaced name from an unquoted word inserts the opening
    # quote at the word start (the parser needs it) and, on a unique match,
    # the closing quote too: 'zz my' -> 'zz "my game"'.
    _seed_tab_cache(v, ["my game", "doc"])
    _send(v, _ch("zz my") + [TAB])
    v.assert_screen_contains('zz "my game"')
    _send(v, [CLEAR])


def test_tab_completes_inside_quotes(v):
    # A word begun with a quote may contain spaces and completes in place:
    # 'zz "my ga' -> 'zz "my game"' (closing quote added on the unique match).
    _seed_tab_cache(v, ["my game", "my demo"])
    _send(v, _ch('zz "my ga') + [TAB])
    v.assert_screen_contains('zz "my game"')
    _send(v, [CLEAR])


def test_tab_quoted_common_prefix(v):
    # Several spaced matches: extends to the common prefix (quote opened,
    # no closing quote yet since the match is still ambiguous).
    _seed_tab_cache(v, ["my game", "my demo"])
    _send(v, _ch("zz m") + [TAB])
    v.assert_screen_contains('zz "my ')
    assert 'zz "my game"' not in v.screen_text(), \
        "ambiguous match should stop at the common prefix"
    _send(v, [CLEAR])
