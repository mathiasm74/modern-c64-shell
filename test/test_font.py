"""font: live-switch the served character ROM between two font sets.

The switch goes through RBCP (SWITCH_SLOT) on the One ROM, so it's hardware-only
-- in VICE there's no One ROM, the RBCP handshake fails fast, and the command
reports "font switch unavailable" and leaves the shell responsive. The actual
font swap (and the RAM-slot assumptions) are validated on the onerom-stock board.
"""

CR = 0x0D
CLEAR = 0x93


def _type(v, text):
    v.write_memory(0x0277, [CLEAR] + [ord(c) for c in text] + [CR])
    v.write_byte(0x00C6, len(text) + 2)


def _wait(v, needle, tries=10, chunk=0.4):
    for _ in range(tries):
        v.run_for(chunk)
        if needle in v.screen_text():
            return True
    return False


def test_font_inert_without_onerom(v):
    # No One ROM in VICE -> the RBCP switch fails -> reported, shell survives.
    v.run_for(0.3)
    _type(v, "font")
    assert _wait(v, "unavailable"), \
        "font should report unavailable in VICE\n%s" % v.screen_text()
    _type(v, "ver")
    assert _wait(v, "Tardis DOS v"), \
        "shell unresponsive after font\n%s" % v.screen_text()
