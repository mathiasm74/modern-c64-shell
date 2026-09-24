"""`color <border|bg|text> [0-15]`: the three colour commands under one name.

run_group (shell.c) re-dispatches `color X args` as `X args`; border/bg/text
are util-bank commands in the dispatch table's unlisted tail. With no number
the member opens its picker, exactly as the bare command does. A bare `color`,
or an unknown member, lists them.
"""

from lib.overlays import seed_util_bank

CR = 0x0D
RUN_STOP = 0x03


def _type(v, text):
    seed_util_bank(v)
    codes = [ord(c) for c in text] + [CR]
    while codes:
        chunk, codes = codes[:8], codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        for _ in range(20):
            v.run_for(0.05)
            if v.read_byte(0x00C6) == 0:
                break


def _after(v, marker):
    rows = v.screen_rows()
    hits = [i for i, r in enumerate(rows) if marker in r]
    return "\n".join(rows[hits[-1] + 1:]) if hits else ""


def _ready(v):
    for _ in range(80):
        if "8>" in v.screen_text():
            return
        v.run_for(0.3)
    raise AssertionError("no prompt\n%s" % v.screen_text())


def _until(v, cond, tries=20):
    for _ in range(tries):
        if cond():
            return True
        v.run_for(0.3)
    return cond()


def test_bare_color_lists_the_members(v):
    _ready(v)
    _type(v, "color")
    assert _until(v, lambda: "picker" in _after(v, "8> color")), v.screen_text()
    out = _after(v, "8> color")
    for sub in ("border", "bg", "text"):
        assert sub in out, "bare color does not list %s\n%s" % (sub, out)


def test_unknown_member_lists_them_too(v):
    _ready(v)
    _type(v, "color purple")
    assert _until(v, lambda: "background" in _after(v, "8> color purple")), \
        v.screen_text()
    assert "Command not found" not in _after(v, "8> color purple")


def test_color_sets_border_bg_and_text(v):
    _ready(v)
    v.write_byte(0xD021, 0x0F)                  # so that 0 is a real change
    _type(v, "color border 5")
    assert _until(v, lambda: v.read_byte(0xD020) & 0x0F == 5), "border not set"
    _type(v, "color bg 0")
    assert _until(v, lambda: v.read_byte(0xD021) & 0x0F == 0), "bg not set"
    _type(v, "color text 7")
    assert _until(v, lambda: v.read_byte(0x0286) & 0x0F == 7), "text not set"


def test_color_without_a_number_opens_the_picker(v):
    _ready(v)
    _type(v, "color border")
    assert _until(v, lambda: "border color" in v.screen_text()
                  and "return to set" in v.screen_text()), \
        "color border did not open the picker\n%s" % v.screen_text()
    v.write_memory(0x0277, [RUN_STOP])          # stop: cancel, colour unchanged
    v.write_byte(0x00C6, 1)
    assert _until(v, lambda: "8>" in v.screen_text()), v.screen_text()
