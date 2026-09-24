"""cat and less LIST a tokenized BASIC program instead of dumping its bytes.

The keyword table lives in the util bank; the files bank far-calls its
detokenizer once per line in print mode (src/banks/files.c list_basic). In
VICE the util bank waits in the shadow at $E000 (seed_files puts it there).

"bas" on the test disk is 10 PRINT "HI PRINT" / 20 DATA ONE,TWO / 30 REM DONE.
"""

from lib.overlays import seed_files, _seed_bank

VICE_DISK = "data/test.d64"

CR = 0x0D
CLEAR = 0x93
SPACE = 0x20


def _send(v, codes):
    codes = [c if isinstance(c, int) else ord(c) for c in codes]
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def _wait(v, needle, tries=40, chunk=0.3):
    for _ in range(tries):
        if needle in v.screen_text():
            return True
        v.run_for(chunk)
    return needle in v.screen_text()


def _ready(v):
    assert _wait(v, "8>", tries=80), "no prompt\n%s" % v.screen_text()


def test_cat_lists_a_basic_program(v):
    _ready(v)
    seed_files(v)
    _send(v, [CLEAR] + list("cat bas") + [CR])
    assert _wait(v, "30 REM DONE"), \
        "cat did not list the program\n%s" % v.screen_text()
    rows = [r.rstrip() for r in v.screen_rows()]
    assert '10 PRINT "HI PRINT"' in rows, rows
    assert "20 DATA ONE,TWO" in rows, rows
    assert "30 REM DONE" in rows, rows
    assert _wait(v, "8>"), "no prompt after the listing"
    assert v.read_byte(0x03A7) == 0, "FAR_DEPTH left set"


def test_cat_basic_leaves_user_ram_alone(v):
    """The listing is streamed a line at a time, so a program loaded at $0801
    survives cat -- unlike staging the whole file in the buffer at $0800."""
    _ready(v)
    seed_files(v)
    v.write_memory(0x0800, [0xA5, 0x5A, 0xC3, 0x3C])
    _send(v, [CLEAR] + list("cat bas") + [CR])
    assert _wait(v, "30 REM DONE")
    assert v.read_memory(0x0800, 4) == [0xA5, 0x5A, 0xC3, 0x3C], \
        "cat of a BASIC program overwrote user RAM"


def test_less_lists_a_basic_program(v):
    _ready(v)
    seed_files(v)
    _send(v, [CLEAR] + list("less bas") + [CR])
    assert _wait(v, "30 REM DONE"), \
        "less did not list the program\n%s" % v.screen_text()
    assert '10 PRINT "HI PRINT"' in v.screen_text()


def test_cat_text_is_unchanged(v):
    """A text file still dumps byte for byte -- the four bytes read to sniff
    for BASIC must come out too."""
    _ready(v)
    seed_files(v)
    _send(v, [CLEAR] + list("cat doc") + [CR])
    assert _wait(v, "l29"), "cat doc broke\n%s" % v.screen_text()
    rows = [r.rstrip() for r in v.screen_rows()]
    assert "l28" in rows and "l29" in rows, rows


def test_cat_basic_without_the_util_bank_says_so(v):
    _ready(v)
    _seed_bank(v, "files_bank.bin")
    v.write_memory(0xE000, [0, 0, 0, 0])        # no bank in the shadow
    _send(v, [CLEAR] + list("cat bas") + [CR])
    assert _wait(v, "no basic support"), \
        "a failed far call was not reported\n%s" % v.screen_text()
    assert _wait(v, "8>"), "cat did not come back\n%s" % v.screen_text()
