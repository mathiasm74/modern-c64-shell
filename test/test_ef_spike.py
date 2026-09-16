"""The EasyFlash proof of mechanism (PLAN.md section 7, phase 1).

The gate for the whole EF port. Four things have to work, and this checks all
four in VICE -- which is itself the point: on the One ROM target the equivalent
paths (SWITCH_SLOT, the stock swap, the swap back) are ALL inert here and cost
days of hardware debugging. On EasyFlash they are register writes the emulator
implements, so the mechanism is testable before any of Tardis is ported onto it.

Hardware still has the final say on (4): emulating enough to run EF game images
is a lower bar than the full register behaviour with the ROM switched off.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

_HERE = os.path.dirname(os.path.abspath(__file__))
_CRT = os.path.join(_HERE, "..", "build", "ef", "spike.crt")

_STOCK_K = os.path.join(_HERE, "..", "stock-roms", "kernal.901227-03.bin")
_STOCK_B = os.path.join(_HERE, "..", "stock-roms", "basic.901226-01.bin")
_HAVE_STOCK = os.path.exists(_STOCK_K) and os.path.exists(_STOCK_B)


def _stock_vice_with_cart():
    """A STOCK C64 with the spike attached.

    Stock on purpose: the EF port targets machines where the KERNAL is the
    factory one and Tardis lives in the cartridge windows, so booting our own
    ROM here would prove nothing. The jumper matters too -- at reset $DE02 is
    $00, i.e. MXG=000, which the spec defines as "GAME from jumper, EXROM high",
    so the jumper is what decides whether the machine comes up in Ultimax and
    runs the cart's start-up code at all.
    """
    import sys as _sys
    _sys.path.insert(0, os.path.join(_HERE, "lib"))
    from vice import Vice
    return Vice(kernal=_STOCK_K, basic=_STOCK_B,
                extra_args=["-cartcrt", _CRT, "+easyflashjumper"])


def _wait(v, needle, tries=40, chunk=0.2):
    """Case-insensitive on purpose.

    The spike prints lowercase ASCII through the STOCK CHROUT, which renders it
    as shifted PETSCII -- uppercase glyphs. That is the first concrete evidence
    for the screen/keyboard decision in PLAN.md section 7: under the stock KERNAL
    the shell would not look like Tardis, which is why screen.s and irq.s are to
    be kept and hooked on the RAM vectors rather than dropped.
    """
    for _ in range(tries):
        if needle.lower() in v.screen_text().lower():
            return True
        v.run_for(chunk)
    return needle.lower() in v.screen_text().lower()


def test_ef_spike_boots_banks_kills_and_returns(v):
    (void) = v                          # the shell's VICE is not the machine here
    if not os.path.exists(_CRT) or not _HAVE_STOCK:
        print("      (skipped: no spike.crt, or no user-supplied stock ROMs)")
        return
    with _stock_vice_with_cart() as sv:
        _body(sv)


def _body(v):

    # (1) BOOT -- the cart supplied the reset vector from Ultimax and reached its
    #     own code, which means Tardis would still boot straight into the shell.
    assert _wait(v, "tardis easyflash spike"), \
        "the cart did not boot from Ultimax:\n%s" % v.screen_text()

    # (2) BANK -- $DE00 changed what is visible at $A000. This is the one that
    #     replaces SWITCH_SLOT, and the markers must DIFFER or nothing switched.
    text = v.screen_text().lower()
    assert "bank 0 at $a000: bank 0" in text, \
        "bank 0's ROMH marker is wrong:\n%s" % text
    assert "bank 1 at $a000: bank 1" in text, \
        "writing $DE00 did not change the $A000 window -- banking does not work:" \
        "\n%s" % text

    # (3) KILL -- $DE02 MXG=100 turns the ROM off, leaving a plain C64. The
    #     helper runs from the cartridge's own $DF00 RAM, because the code doing
    #     the switch cannot live in the window it is switching away.
    v.write_memory(0x0277, [0x4B])      # "K"
    v.write_byte(0x00C6, 1)
    assert _wait(v, "READY."), \
        "the cart did not kill itself to stock BASIC:\n%s" % v.screen_text()
    # ...and it really is gone: $A000 must read as BASIC ROM, not our marker.
    a000 = bytes(v.read_memory(0xA000, 6))
    assert a000 != b"bank 0" and a000 != b"bank 1", \
        "the cartridge ROM is still mapped at $A000 after MXG=100"

    # (4) RETURN -- the registers still answer with the ROM off, so software can
    #     switch back. This is what replaces the RBCP swap-back, and it is the
    #     half that decides whether the port is possible at all.
    for ch in "SYS 57120\r":
        v.write_memory(0x0277, [ord(ch)])
        v.write_byte(0x00C6, 1)
        for _ in range(20):
            v.run_for(0.05)
            if v.read_byte(0x00C6) == 0:
                break
    assert _wait(v, "tardis easyflash spike"), \
        "could not switch the cartridge back on from BASIC -- $DE02 stopped " \
        "responding with the ROM off, which would sink the EF port:\n%s" \
        % v.screen_text()
