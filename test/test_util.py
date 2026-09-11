"""Utility commands: peek, poke, reset.

peek/poke take DECIMAL numbers by default and hex when prefixed with '$' (the
C64 convention -- so `poke 53280 0`, the address from BASIC, works, and
`poke $d020 0` is the same register). The scratch target is user RAM ($2000),
which survives the overlay call (the overlay clobbers zero page as it runs).
reset reboots
through the reset vector. peek/poke are now files-overlay commands (cmds
12/13), so each typed command seeds that overlay first. (The `device` command
now probes the bus, so its tests live in test_device.py with a drive attached.)
"""

from lib.overlays import seed_files

CR = 0x0D
CLEAR = 0x93


def _send(v, codes):
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def _ch(s):
    return [ord(c) for c in s]


def _type_cmd(v, text, clear=False):
    """Seed the files overlay (peek/poke live there now), then type a command
    line through the 10-byte keyboard buffer (chunked) and submit it."""
    seed_files(v)
    codes = ([CLEAR] if clear else []) + _ch(text) + [CR]
    while codes:
        chunk, codes = codes[:8], codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        v.run_for(0.3)


# $2000 is user RAM -- clear of the files overlay's cc65 zeropage ($40-$5F)
# and its other ZP scratch, so it survives the overlay call. (peek/poke of
# zero page itself is now unreliable, since the overlay clobbers ZP as it runs
# -- the trade for moving them out of the resident ROM.) $2000 == 8192 decimal,
# which lets the decimal/hex tests target it both ways.
def test_poke_writes_memory(v):
    # hex: '$' prefix. poke $4a to $2000.
    _type_cmd(v, "poke $2000 $4a")
    assert v.read_byte(0x2000) == 0x4A, "poke $2000 $4a did not write $4A"


def test_poke_decimal_default(v):
    # bare numbers are decimal: 8192 == $2000, 74 == $4A. The whole point of the
    # fix -- a BASIC-style `poke 8192 74` must NOT be read as hex.
    _type_cmd(v, "poke 8192 74")
    assert v.read_byte(0x2000) == 0x4A, \
        "poke 8192 74 (decimal) did not write $4A to $2000 (decimal parse broken)"


def test_peek_reads_memory(v):
    v.write_byte(0x2000, 0x3C)              # plant a value to read back
    _type_cmd(v, "peek $2000", clear=True)
    v.assert_screen_contains("$3c")


def test_peek_decimal_default(v):
    v.write_byte(0x2000, 0x3C)
    _type_cmd(v, "peek 8192", clear=True)   # 8192 decimal == $2000
    v.assert_screen_contains("$3c")


def test_peek_hexdump_range(v):
    # `peek <addr> <count>` hexdumps a range -- 8 bytes per row with an address
    # label, for reading a loaded program's bytes (e.g. a BASIC line). hex addr,
    # decimal count.
    v.write_memory(0x2100, [0xAA, 0xBB, 0xCC, 0xDD])
    _type_cmd(v, "peek $2100 4", clear=True)
    txt = v.screen_text()
    assert "$2100:" in txt, "hexdump missing the address label: " + txt
    assert "aa bb cc dd" in txt, "hexdump bytes missing: " + txt


def test_reset_reboots(v):
    _send(v, _ch("reset") + [CR])
    v.run_for(0.5)
    assert "Tardis DOS" in v.screen_text(), "reset did not redraw the boot banner"
    # the rebooted shell still takes commands
    _send(v, [CLEAR] + _ch("zq") + [CR])
    v.assert_screen_contains("Command not found: zq")


