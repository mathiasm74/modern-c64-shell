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
    # The C= colours live in the full C= table now (it came from the KERNAL and
    # carries the graphics too), so read them from the digit keys' matrix slots.
    tab = v.read_memory(_symbol_addr("keytab_cbm"), 65)
    got = [tab[i] for i in (56, 59, 8, 11, 16, 19, 24, 27)]
    assert got == want_cbm, "C= colours: %s want %s" % (
        [hex(b) for b in got], [hex(b) for b in want_cbm])


_STOCK_KERNAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "..", "stock-roms", "kernal.901227-03.bin")


def _stock_table(addr, n=65):
    with open(_STOCK_KERNAL, "rb") as f:
        rom = f.read()
    return list(rom[addr - 0xE000:addr - 0xE000 + n])


def test_cbm_table_matches_the_kernal(v):
    """C= + key produces the PETSCII graphics the real KERNAL produces.

    Our matrix indexing is the same as the KERNAL's, so its own C= decode table
    ($EC03) drops straight in -- which is the point: sixty-odd graphics codes
    are not something to transcribe from memory. This checks ours still equals
    the ROM's, so a future edit cannot quietly drift.

    Four slots differ by design: the modifier keys (15/52/58/61), where the
    KERNAL stores flag bits and we store $00 for "emits nothing", and the
    no-key sentinel at 64. The '@' slot stays faithful to the ROM here; the
    underscore override for VICE's symbolic keymap is applied in the decode
    path, not the table.
    """
    if not os.path.exists(_STOCK_KERNAL):
        return                          # skip: no user-supplied stock ROMs

    want = _stock_table(0xEC03)
    for i in (15, 52, 58, 61, 64):
        want[i] = 0x00
    got = v.read_memory(_symbol_addr("keytab_cbm"), 65)
    assert got == want, "C= table drifted from the KERNAL's\n got: %s\nwant: %s" % (
        " ".join("%02X" % b for b in got), " ".join("%02X" % b for b in want))


def test_ctrl_colours_match_the_kernal(v):
    """CTRL+1..8 emit what the KERNAL's own CTRL table emits for those keys.

    We keep a small table of our own because our CTRL path is CTRL+letter ->
    control code, which is NOT what the stock table does -- only the digit row
    agrees, and this pins that agreement.
    """
    if not os.path.exists(_STOCK_KERNAL):
        return

    ctrl = _stock_table(0xEC78)
    # matrix slots for the digit keys 1..8, in keycap order
    digits = [56, 59, 8, 11, 16, 19, 24, 27]
    want = [ctrl[i] for i in digits]
    got = v.read_memory(_symbol_addr("ctrl_color"), 8)
    assert got == want, "CTRL colours differ from the KERNAL's\n got: %s\nwant: %s" % (
        " ".join("%02X" % b for b in got), " ".join("%02X" % b for b in want))


def test_scan_settles_before_reading_the_matrix(v):
    """The scan must let the matrix line settle before sampling it.

    The lines are long -- mainboard trace, connector, keyboard PCB -- and a
    contact that has aged or oxidised adds series resistance, raising the RC.
    Reading back-to-back after selecting a line then samples it before it has
    pulled down and the key reads as "not pressed", so an entire row goes dead
    while the hardware is only marginal.

    This is not hypothetical: a real machine showed row 4 (9 I J 0 M K O N)
    dead under Tardis and working under the STOCK KERNAL, whose scan loop puts
    ldx/pha between its write and its read. We had nothing between ours.

    VICE cannot reproduce a resistive contact, so assert the property instead:
    there IS a gap between selecting a line ($DC00) and reading it ($DC01).
    """
    (void) = v

    rom = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "build", "kernal.bin"), "rb").read()
    sel = bytes([0x8D, 0x00, 0xDC])         # sta $DC00
    rd = bytes([0xAD, 0x01, 0xDC])          # lda $DC01
    gaps = []
    i = 0
    while True:
        i = rom.find(sel, i)
        if i < 0:
            break
        j = rom.find(rd, i)
        if 0 <= j - (i + 3) < 40:
            gaps.append(j - (i + 3))
        i += 1
    assert gaps, "no select/read pair found -- did the scan change shape?"
    # The stock KERNAL's scan-loop gap is 3 bytes (ldx #$08 ; pha = 5 cycles).
    # Ours is deliberately longer, since the cost is ~0.5% of a frame's IRQ
    # budget and the margin is what keeps an ageing keyboard working.
    assert min(gaps) >= 5, \
        "keyboard scan reads $DC01 only %d bytes after selecting on $DC00 -- " \
        "too tight for a marginal contact (stock leaves 3)" % min(gaps)
