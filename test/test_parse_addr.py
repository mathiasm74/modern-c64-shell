"""parse_addr (src/parse_addr.s): the shell's number parser.

DECIMAL by default, HEX when prefixed with '$' -- the C64 convention, so
`sys 54301` matches the number a BASIC user would type and `sys $d41d` is the
same register. `sys` feeds the result straight into a JSR, so a wrong value
jumps somewhere wrong; and it is hand-written assembly (cc65 compiled the same
~20 lines of C into 251 bytes, the largest resident helper after the stock-swap
glue), so it is exercised directly here rather than through one end-to-end
`sys` case.

Its own module because calling the routine with run_at() parks the CPU, which
would strand every later test sharing the VICE instance.
"""

# The number parser `sys` feeds straight into a JSR, so a wrong result jumps
# somewhere wrong. It is hand-written assembly (cc65 compiled the same ~20 lines
# of C into 251 bytes), so exercise it directly rather than trusting one
# end-to-end `sys` case: call it with an ML stub and check the value it returns.

import os

_LABELS = os.path.join(os.path.dirname(__file__), "..", "build", "labels.txt")


def _label_addr(name):
    with open(_LABELS) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 3 and parts[2].lstrip(".") == name:
                return int(parts[1], 16) & 0xFFFF
    raise AssertionError("label %r not found" % name)


def _parse(v, text):
    """Run parse_addr(text) on the emulated machine and return its result."""
    addr = _label_addr("_parse_addr")
    v.write_memory(0x1100, [ord(c) for c in text] + [0])
    v.write_memory(0x1000, [
        0xA9, 0x00,                     # LDA #$00   (string lo)
        0xA2, 0x11,                     # LDX #$11   (string hi)
        0x20, addr & 0xFF, addr >> 8,   # JSR _parse_addr
        0x8D, 0xF0, 0x10,               # STA $10F0
        0x8E, 0xF1, 0x10,               # STX $10F1
        0x4C, 0x0D, 0x10,               # JMP self
    ])
    v.write_memory(0x10F0, [0xEE, 0xEE])
    v.run_at(0x1000, 0.3)
    return v.read_byte(0x10F0) | (v.read_byte(0x10F1) << 8)


def test_parse_addr_decimal_and_hex(v):
    cases = [
        ("0", 0),
        ("7", 7),
        ("53280", 53280),       # $D020, the number a BASIC user types
        ("54301", 54301),       # the SIDKick trigger `sys` exists for
        ("65535", 65535),       # 16-bit ceiling
        ("$0", 0),
        ("$d020", 0xD020),      # lowercase hex
        ("$D020", 0xD020),      # uppercase hex
        ("$ffff", 0xFFFF),
        ("$a5", 0x00A5),
        ("", 0),                # empty -> 0, not garbage
        ("$", 0),
        ("abc", 0),             # unparseable -> 0
        ("12x", 12),            # stops at the first non-digit
        ("$1fg", 0x001F),
    ]
    for text, want in cases:
        got = _parse(v, text)
        assert got == want, \
            "parse_addr(%r) = $%04X (%d), want $%04X (%d)" % (
                text, got, got, want, want)
