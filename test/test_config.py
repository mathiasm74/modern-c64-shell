"""Appearance commands: border / bg / text colors and the prompt string.

border/bg poke the VIC registers ($D020/$D021), text sets the KERNAL text
color ($0286), and prompt changes the symbol main() shows. All four now live
in the files overlay (cmds 8-11) -- the bodies cost overlay flash, not the
16KB ROM -- so the tests seed that overlay first. No disk needed (these never
touch the drive).
"""

from lib.overlays import seed_files

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


def test_prompt_changes(v):
    _run(v, "prompt %")
    # the new prompt "% " (note the trailing space) is not a substring of the
    # typed "prompt %", so seeing it proves the prompt actually changed.
    for _ in range(6):
        if "% " in v.screen_text():
            break
        v.run_for(0.3)
    assert "% " in v.screen_text(), "prompt did not change"
