"""Tab completion: TAB ($09) completes the command word.

When the line is a bare prefix (no space yet) and exactly one command name
starts with it, readline appends the rest of that name and a space. Ambiguous
or unknown prefixes are left untouched. (Physically, the CTRL key emits $09 --
GUI-only; the logic here is driven by injecting $09 into the buffer.)
"""

TAB = 0x09
CR = 0x0D
CLEAR = 0x93


def _send(v, codes):
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.4)


def _ch(s):
    return [ord(c) for c in s]


def test_unique_prefix_completes(v):
    # "he" -> "help " -> help runs and prints its header.
    _send(v, [CLEAR] + _ch("he") + [TAB, CR])
    v.assert_screen_contains("Commands")


def test_unknown_prefix_left_alone(v):
    _send(v, [CLEAR] + _ch("zz") + [TAB, CR])
    v.assert_screen_contains("Command not found: zz")


def test_ambiguous_prefix_does_not_complete(v):
    # "e" matches both echo and exit, so TAB must not complete it.
    _send(v, [CLEAR] + _ch("e") + [TAB, CR])
    v.assert_screen_contains("Command not found: e")
