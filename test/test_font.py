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


def test_base_ram_slot_is_initialized_at_boot(v):
    """reset.s must clear BASE_SLOT ($02CE), the RAM slot the base set is served
    from, which bank_restore (launch.s) switches back to after a bank command.

    Page-2 RAM is power-on garbage, so leaving this uninitialized would make
    roughly 255/256 cold boots switch back to a slot that is not serving the
    base after the very first disk command -- the same hazard reset.s already
    guards for KBD_LAYOUT. Hardware-only in effect (the swap is inert in VICE),
    but the initialization is checkable here.
    """
    assert v.read_byte(0x02CE) == 0, \
        "BASE_SLOT ($02CE) = $%02X after boot, must be 0 (RAM slot 0)" % \
        v.read_byte(0x02CE)
