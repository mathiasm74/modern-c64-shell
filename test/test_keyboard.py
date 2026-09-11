"""Keyboard decode tables (src/irq.s).

The matrix *scan* (which physical key is down, SHIFT detection, repeat) can
only be exercised through real key matrix state, so it stays GUI-verified
(`make run`). But the decode tables it indexes -- keytab (unshifted) and
keytab_shift (SHIFT held) -- are hand-entered and easy to typo, so we check
their bytes directly: read the table out of ROM at the address ld65 recorded
in build/labels.txt and assert the entries that matter.

The shifted layout is the C64-native one (shift-1=!, shift-2=", ... shift-6=&,
shift-/=?, shift-:=[, shift-;=]). That's what VICE's default symbolic keyboard
mapping expects, so a host '!' (which it sends as shift-1) decodes to '!'.
"""

import os

_LABELS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "build", "labels.txt")


def _symbol_addr(name):
    """Address of an exported symbol from the ld65 VICE label file."""
    with open(_LABELS) as f:
        for line in f:                      # "al 00E1F4 .keytab_shift"
            parts = line.split()
            if len(parts) >= 3 and parts[2] == "." + name:
                return int(parts[1], 16) & 0xFFFF
    raise AssertionError("symbol %s not in %s (build first)" % (name, _LABELS))


# Matrix code for each top-row number key (standard C64 matrix order).
_NUM = {"1": 56, "2": 59, "3": 8, "4": 11, "5": 16,
        "6": 19, "7": 24, "8": 27, "9": 32, "0": 35}


def test_unshifted_number_row(v):
    base = _symbol_addr("keytab")
    tab = v.read_memory(base, 64)
    for digit, code in _NUM.items():
        assert tab[code] == ord(digit), \
            "keytab[%d] = $%02X, expected '%s'" % (code, tab[code], digit)


def test_shifted_number_row(v):
    # The reported bug: shifted number keys emitted the bare digit. The native
    # shifted row is ! " # $ % & ' ( ) and shift-0 stays 0.
    base = _symbol_addr("keytab_shift")
    tab = v.read_memory(base, 64)
    want = {"1": "!", "2": '"', "3": "#", "4": "$", "5": "%",
            "6": "&", "7": "'", "8": "(", "9": ")", "0": "0"}
    for digit, sym in want.items():
        code = _NUM[digit]
        assert tab[code] == ord(sym), \
            "shift-%s = $%02X, expected '%s'" % (digit, tab[code], sym)


def test_shifted_punctuation_and_cursor(v):
    base = _symbol_addr("keytab_shift")
    tab = v.read_memory(base, 64)
    # punctuation that the C64 makes with SHIFT (matrix code -> shifted char)
    assert tab[44] == ord(">"), "shift-. should be '>'"
    assert tab[47] == ord("<"), "shift-, should be '<'"
    assert tab[55] == ord("?"), "shift-/ should be '?'"
    assert tab[45] == ord("["), "shift-: should be '['"
    assert tab[50] == ord("]"), "shift-; should be ']'"
    # letters fold to uppercase; cursor and HOME get the shifted control codes
    assert tab[10] == ord("A"), "shift-a should be 'A'"
    assert tab[2] == 0x9D, "shift-cursor-right should be cursor-left ($9D)"
    assert tab[7] == 0x91, "shift-cursor-down should be cursor-up ($91)"
    assert tab[51] == 0x93, "shift-HOME should be CLR ($93)"
    # the shift keys themselves emit nothing
    assert tab[15] == 0x00 and tab[52] == 0x00, "a SHIFT key must emit nothing"


def test_colour_code_tables(v):
    """CTRL+1..8 and C=+1..8 emit the sixteen PETSCII colour codes.

    These are control codes, not characters, so they cannot live in the key
    tables and are reached only through a modifier -- and they are the only way
    to get a colour into a BASIC string, since you cannot type one. The live
    matrix is hardware-only (the harness injects into the keyboard buffer, not
    the matrix), but the TABLES are checkable straight out of ROM.
    """
    want_ctrl = [0x90, 0x05, 0x1C, 0x9F,    # black, white, red, cyan
                 0x9C, 0x1E, 0x1F, 0x9E]    # purple, green, blue, yellow
    want_cbm = [0x81, 0x95, 0x96, 0x97,     # orange, brown, lt red, dk grey
                0x98, 0x99, 0x9A, 0x9B]     # grey, lt green, lt blue, lt grey

    got = v.read_memory(_symbol_addr("ctrl_color"), 8)
    assert got == want_ctrl, "CTRL colours: %s want %s" % (
        [hex(b) for b in got], [hex(b) for b in want_ctrl])
    got = v.read_memory(_symbol_addr("cbm_color"), 8)
    assert got == want_cbm, "C= colours: %s want %s" % (
        [hex(b) for b in got], [hex(b) for b in want_cbm])
