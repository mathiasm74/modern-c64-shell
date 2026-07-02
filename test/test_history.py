"""Command history: up/down arrows recall previously submitted commands.

readline stores each non-empty submitted line in a ring buffer; cursor-up
($91) recalls older entries and cursor-down ($11) walks back toward the fresh
line. Each test submits "aa" then "bb" and then navigates at most two steps
back, so it reaches its own entries regardless of history left by earlier
tests (they share one VICE). A trailing edit makes the dispatched command
unique, so "Command not found: <x>" shows exactly which entry was recalled.
"""

UP = 0x91
DOWN = 0x11
CR = 0x0D
CLEAR = 0x93


def _send(v, codes):
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def _ch(s):
    return [ord(c) for c in s]


def test_up_recalls_previous_command(v):
    _send(v, _ch("clear") + [CR] + _ch("aa") + [CR])
    _send(v, _ch("bb") + [CR])
    _send(v, [UP] + _ch("z") + [CR])            # UP -> "bb"; append -> "bbz"
    v.assert_screen_contains("Command not found: bbz")


def test_up_twice_recalls_older_command(v):
    _send(v, _ch("clear") + [CR] + _ch("aa") + [CR])
    _send(v, _ch("bb") + [CR])
    _send(v, [UP, UP] + _ch("z") + [CR])        # UP UP -> "aa"; append -> "aaz"
    v.assert_screen_contains("Command not found: aaz")
    assert "Command not found: bbz" not in v.screen_text(), \
        "up-twice should reach 'aa', not stop at 'bb'"


def test_down_walks_back_to_newer(v):
    _send(v, _ch("clear") + [CR] + _ch("aa") + [CR])
    _send(v, _ch("bb") + [CR])
    _send(v, [UP, UP, DOWN] + _ch("z") + [CR])  # UP UP -> aa, DOWN -> "bb" -> "bbz"
    v.assert_screen_contains("Command not found: bbz")
