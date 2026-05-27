"""Appearance commands: border / bg / text colors and the prompt string.

Colors poke the VIC registers ($D020 border, $D021 background) and the KERNAL
text color ($0286); prompt changes the symbol main() shows before each line.
"""

CR = 0x0D


def _send(v, codes):
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def _ch(s):
    return [ord(c) for c in s]


def test_border_color(v):
    _send(v, _ch("border 2") + [CR])
    assert (v.read_byte(0xD020) & 0x0F) == 2, "border color not set"


def test_background_color(v):
    _send(v, _ch("bg 0") + [CR])
    assert (v.read_byte(0xD021) & 0x0F) == 0, "background color not set"


def test_text_color(v):
    _send(v, _ch("text 7") + [CR])
    assert (v.read_byte(0x0286) & 0x0F) == 7, "text color not set"


def test_prompt_changes(v):
    _send(v, _ch("prompt %") + [CR])
    # the new prompt "% " (note the trailing space) is not a substring of the
    # typed "prompt %", so seeing it proves the prompt actually changed.
    assert "% " in v.screen_text(), "prompt did not change"
