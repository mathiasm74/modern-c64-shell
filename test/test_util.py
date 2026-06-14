"""Utility commands: peek, poke, reset.

peek/poke take DECIMAL numbers by default and hex when prefixed with '$' (the
C64 convention -- so `poke 53280 0`, the address from BASIC, works, and
`poke $d020 0` is the same register). $0050 is free zero page (no BASIC, and
clear of cc65's $02-$1B), so it's a safe scratch target; decimal 80 is the same
cell, which lets the decimal/hex tests target it both ways. reset reboots
through the reset vector. (The `device` command now probes the bus, so its
tests live in test_device.py with a drive attached.)
"""

CR = 0x0D
CLEAR = 0x93


def _send(v, codes):
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def _ch(s):
    return [ord(c) for c in s]


def _type_cmd(v, text, clear=False):
    """Type a command line through the 10-byte keyboard buffer (chunked) and
    submit it with RETURN."""
    codes = ([CLEAR] if clear else []) + _ch(text) + [CR]
    while codes:
        chunk, codes = codes[:8], codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        v.run_for(0.3)


def test_poke_writes_memory(v):
    # hex: '$' prefix. poke $4a to $0050.
    _type_cmd(v, "poke $50 $4a")
    assert v.read_byte(0x0050) == 0x4A, "poke $50 $4a did not write $4A to $0050"


def test_poke_decimal_default(v):
    # bare numbers are decimal: 80 == $50, 74 == $4A. The whole point of the
    # fix -- a BASIC-style `poke 80 74` must NOT be read as hex.
    _type_cmd(v, "poke 80 74")
    assert v.read_byte(0x0050) == 0x4A, \
        "poke 80 74 (decimal) did not write $4A to $0050 (decimal parse broken)"


def test_peek_reads_memory(v):
    v.write_byte(0x0050, 0x3C)              # plant a value to read back
    _type_cmd(v, "peek $50", clear=True)
    v.assert_screen_contains("$3c")


def test_peek_decimal_default(v):
    v.write_byte(0x0050, 0x3C)
    _type_cmd(v, "peek 80", clear=True)     # 80 decimal == $50
    v.assert_screen_contains("$3c")


def test_peek_hexdump_range(v):
    # `peek <addr> <count>` hexdumps a range -- 8 bytes per row with an address
    # label, for reading a loaded program's bytes (e.g. a BASIC line). hex addr,
    # decimal count.
    v.write_memory(0x0340, [0xAA, 0xBB, 0xCC, 0xDD])
    _type_cmd(v, "peek $340 4", clear=True)
    txt = v.screen_text()
    assert "$0340:" in txt, "hexdump missing the address label: " + txt
    assert "aa bb cc dd" in txt, "hexdump bytes missing: " + txt


def test_reset_reboots(v):
    _send(v, _ch("reset") + [CR])
    v.run_for(0.5)
    assert "C64 Shell ROM" in v.screen_text(), "reset did not redraw the boot banner"
    # the rebooted shell still takes commands
    _send(v, [CLEAR] + _ch("zq") + [CR])
    v.assert_screen_contains("Command not found: zq")
