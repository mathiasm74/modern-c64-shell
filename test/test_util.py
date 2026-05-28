"""Utility commands: peek, poke, reset.

peek/poke read and write memory in hex (a leading '$' is optional). $0050 is
free zero page (no BASIC, and clear of cc65's $02-$1B), so it's a safe scratch
target. reset reboots through the reset vector. (The `device` command now
probes the bus, so its tests live in test_device.py with a drive attached.)
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


def test_reset_reboots(v):
    _send(v, _ch("reset") + [CR])
    v.run_for(0.5)
    assert "C64 Shell ROM" in v.screen_text(), "reset did not redraw the boot banner"
    # the rebooted shell still takes commands
    _send(v, [CLEAR] + _ch("zq") + [CR])
    v.assert_screen_contains("Command not found: zq")
