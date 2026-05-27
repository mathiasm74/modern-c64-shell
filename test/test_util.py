"""Utility commands: peek, poke, device, reset.

peek/poke read and write memory in hex (a leading '$' is optional). $0050 is
free zero page (no BASIC, and clear of cc65's $02-$1B), so it's a safe scratch
target. device sets the default IEC unit; reset reboots through the reset
vector.
"""

CR = 0x0D
CLEAR = 0x93


def _send(v, codes):
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def _ch(s):
    return [ord(c) for c in s]


def test_poke_writes_memory(v):
    # "poke 50 4a" in two batches (the whole line won't fit the 10-byte buffer).
    v.write_memory(0x0277, _ch("poke 50 4"))
    v.write_byte(0x00C6, 9)
    v.run_for(0.3)
    v.write_memory(0x0277, _ch("a") + [CR])
    v.write_byte(0x00C6, 2)
    v.run_for(0.3)
    assert v.read_byte(0x0050) == 0x4A, "poke did not write $4A to $0050"


def test_peek_reads_memory(v):
    v.write_byte(0x0050, 0x3C)              # plant a value to read back
    _send(v, [CLEAR] + _ch("peek 50") + [CR])
    v.assert_screen_contains("$3c")


def test_device_sets_default(v):
    _send(v, [CLEAR] + _ch("device 9") + [CR])
    # the typed line and the printed confirmation both read "device 9"
    assert v.screen_text().count("device 9") >= 2, "device did not confirm the change"


def test_reset_reboots(v):
    _send(v, _ch("reset") + [CR])
    v.run_for(0.5)
    assert "C64 Shell ROM" in v.screen_text(), "reset did not redraw the boot banner"
    # the rebooted shell still takes commands
    _send(v, [CLEAR] + _ch("zq") + [CR])
    v.assert_screen_contains("Command not found: zq")
