"""Swedish characters: the Aring/Ae/Oe display + keyboard path.

Two halves, both checkable in VICE even though the live keyboard *matrix* (and
the `font` command that activates the Swedish tables) are hardware-only:

  * pet2scr (src/screen.s) turns the typed/printed PETSCII byte into a screen
    code. The Swedish charset draws ae/oe/aring at screen codes $1B/$1C/$1D and
    the uppercase Ae/Oe/Aring at $5B/$5C/$5D, so pet2scr must map PETSCII
    $5B-$5D -> $1B-$1D (already) and $DB-$DD -> $5B-$5D (added for uppercase).
    We call pet2scr directly via an ML stub and read back the screen codes.

  * keytab_se / keytab_se_shift (src/irq.s) are the Swedish decode tables the
    scan uses when KBD_LAYOUT=1. Like test_keyboard.py we read the bytes out of
    ROM and assert the entries that differ from the US tables.
"""

import os

_LABELS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "build", "labels.txt")


def _symbol_addr(name):
    with open(_LABELS) as f:
        for line in f:                      # "al 00E390 .keytab_se"
            parts = line.split()
            if len(parts) >= 3 and parts[2] == "." + name:
                return int(parts[1], 16) & 0xFFFF
    raise AssertionError("symbol %s not in %s (build first)" % (name, _LABELS))


def _spin(addr):
    return [0x4C, addr & 0xFF, (addr >> 8) & 0xFF]


def test_pet2scr_swedish_screen_codes(v):
    # Lowercase ae/oe/aring come from $5B/$5C/$5D, uppercase from $DB/$DC/$DD.
    pet = _symbol_addr("pet2scr")
    lo, hi = pet & 0xFF, (pet >> 8) & 0xFF
    cases = [(0x5B, 0x1B), (0x5C, 0x1C), (0x5D, 0x1D),   # ae oe aring
             (0xDB, 0x5B), (0xDC, 0x5C), (0xDD, 0x5D)]   # Ae Oe Aring
    out = 0x2000
    stub = []
    for i, (inp, _exp) in enumerate(cases):
        # LDA #inp ; JSR pet2scr ; STA out+i
        stub += [0xA9, inp, 0x20, lo, hi,
                 0x8D, (out + i) & 0xFF, ((out + i) >> 8) & 0xFF]
    stub += _spin(0x1000 + len(stub))
    v.write_memory(0x1000, stub)
    v.run_at(0x1000, 0.2)
    res = v.read_memory(out, len(cases))
    for i, (inp, exp) in enumerate(cases):
        assert res[i] == exp, \
            "pet2scr($%02X) = $%02X, expected $%02X" % (inp, res[i], exp)


def test_keytab_se_unshifted(v):
    tab = v.read_memory(_symbol_addr("keytab_se"), 64)
    # The three Swedish letters, lowercase (the [ \ ] codes the charset reshapes)
    assert tab[46] == 0x5B, "Swedish '@' key (46) should give ae ($5B)"
    assert tab[45] == 0x5C, "Swedish ':' key (45) should give oe ($5C)"
    assert tab[50] == 0x5D, "Swedish ';' key (50) should give aring ($5D)"
    # Displaced shell-critical symbols stay reachable
    assert tab[49] == ord("@"), "'@' relocates to matrix 49"
    assert tab[48] == ord(":"), "':' relocates to matrix 48"
    assert tab[53] == ord(";"), "';' relocates to matrix 53"
    # Letters, digits and the bottom row are unchanged from US
    assert tab[10] == ord("a") and tab[35] == ord("0")
    assert tab[47] == ord(",") and tab[55] == ord("/")


def test_keytab_se_shifted(v):
    tab = v.read_memory(_symbol_addr("keytab_se_shift"), 64)
    # Uppercase Swedish letters reach the upper glyphs via pet2scr ($DB-$DD)
    assert tab[46] == 0xDB, "shift Swedish '@' key should give Ae ($DB)"
    assert tab[45] == 0xDC, "shift Swedish ':' key should give Oe ($DC)"
    assert tab[50] == 0xDD, "shift Swedish ';' key should give Aring ($DD)"
    # '*' and '+' land on the shifted symbol keys
    assert tab[48] == ord("*"), "shift matrix 48 should give '*'"
    assert tab[53] == ord("+"), "shift matrix 53 should give '+'"
    # letters still fold to uppercase, shift keys still emit nothing
    assert tab[10] == ord("A")
    assert tab[15] == 0x00 and tab[52] == 0x00


def test_default_layout_is_us(v):
    # KBD_LAYOUT ($02CB) must boot at 0 so the US/symbolic tables are active.
    v.run_for(0.3)
    assert v.read_byte(0x02CB) == 0x00, "KBD_LAYOUT should default to 0 (US)"


def test_uppercase_swedish_char_is_accepted_at_prompt(v):
    # The reported bug: shift-Ae/Oe/Aring emit $DB-$DD, but readline only stored
    # $20-$7E, so the capitals were dropped on input. Inject the byte straight
    # into the keyboard buffer (bypassing the matrix) and confirm it lands on
    # screen as the uppercase screen code $5B (Ae) -- i.e. it was NOT filtered.
    # A prior test in this module parks the CPU via run_at, so cold-boot the
    # shell (PC = the reset handler at $FFFC/$FFFD) to get a live readline.
    rv = v.read_byte(0xFFFC) | (v.read_byte(0xFFFD) << 8)
    v.run_at(rv, 0.3)
    for _ in range(10):                  # wait for the prompt
        if "Ready." in v.screen_text():
            break
        v.run_for(0.2)
    v.write_memory(0x0277, [0xDB])       # shift-Ae
    v.write_byte(0x00C6, 1)              # one key waiting
    sc = 0
    for _ in range(10):                  # poll until the shell consumes the key
        v.run_for(0.2)
        pnt = v.read_byte(0xD1) | (v.read_byte(0xD2) << 8)   # current line start
        col = v.read_byte(0xD3)                              # cursor column
        if col >= 3:                     # prompt "> " (2) + the typed char
            sc = v.read_byte(pnt + col - 1) & 0x7F           # mask the cursor bit
            break
    assert sc == 0x5B, \
        "typed $DB should land as screen code $5B (Ae), got $%02X" % sc


def test_pet2scr_petscii_graphics(v):
    """The PETSCII graphics set ($A0-$FF) maps to its screen codes.

    $A0-$BF -> $60-$7F and $C0-$FF -> $40-$7F, the standard mapping. The
    uppercase Swedish letters are just three entries inside that second range
    ($DB-$DD -> $5B-$5D), which is why they no longer need a rule of their own:
    the general one covers them, and the rest of the graphics came with it.
    """
    pet = _symbol_addr("pet2scr")
    lo, hi = pet & 0xFF, (pet >> 8) & 0xFF
    cases = [(0xA0, 0x60),          # C= + space: the solid block
             (0xA1, 0x61), (0xBF, 0x7F),
             (0xC0, 0x40), (0xDB, 0x5B),    # $DB is also uppercase Ae
             (0xDD, 0x5D), (0xFF, 0x7F)]
    out = 0x2000
    stub = []
    for i, (inp, _exp) in enumerate(cases):
        stub += [0xA9, inp, 0x20, lo, hi,
                 0x8D, (out + i) & 0xFF, ((out + i) >> 8) & 0xFF]
    stub += _spin(0x1000 + len(stub))
    v.write_memory(0x1000, stub)
    v.run_at(0x1000, 0.2)
    res = v.read_memory(out, len(cases))
    for i, (inp, exp) in enumerate(cases):
        assert res[i] == exp, \
            "pet2scr($%02X) = $%02X, expected $%02X" % (inp, res[i], exp)
