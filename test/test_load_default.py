"""`load` is fast by default, falls back without comment, and has `--slow`.

PLAN.md section 9. The fast path is tried first (src/banks/disk_bank.c,
disk_load); when the drive has none, or the fast load does not complete, the
standard IEC path runs instead and reports whatever the DRIVE says -- so a
missing file still reads "62 file not found", never "fast load failed".
`load --slow` goes straight to the standard path. `fload` stays the fast path
alone, for finding out whether a drive is really fast-loading.

On the VICE 1541 the fast path is src/drive1541.s, whose directory lookup takes
only closed PRG files and understands `*` and `?` -- anything else it passes
over, and the fallback picks up.
"""

from lib.overlays import seed_disk_bank

VICE_DISK = "data/test.d64"

CLEAR = 0x93
CR = 0x0D

# test/data/test.d64's `prog`: 31 bytes at $2000.
PROG = [0xA2, 0x00, 0xBD, 0x0E, 0x20, 0xF0, 0x06, 0x20]


def _prompt(v):
    for _ in range(20):
        v.run_for(0.3)
        if "8>" in v.screen_text():
            return
    raise AssertionError("no prompt:\n%s" % v.screen_text())


def _load(v, args):
    """Type `load <args>` on a clear screen; return the screen once the
    command has finished (the prompt is back below it)."""
    seed_disk_bank(v)
    v.write_memory(0x2000, [0] * len(PROG))
    codes = [CLEAR] + [ord(c) for c in "load " + args] + [CR]
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    for _ in range(40):
        v.run_for(0.5)
        rows = [r.rstrip() for r in v.screen_rows() if r.strip()]
        if len(rows) >= 2 and rows[-1].endswith(">"):
            return v.screen_text()
    raise AssertionError("load %s never finished:\n%s" % (args, v.screen_text()))


def _loaded(v):
    return list(v.read_memory(0x2000, len(PROG))) == PROG


def test_load_takes_the_fast_path(v):
    _prompt(v)
    text = _load(v, "prog")
    assert "Fast-loaded $2000-$201e" in text, \
        "load did not use the fast path:\n%s" % text
    assert _loaded(v), "the program is not at $2000"


def test_load_slow_takes_the_standard_path(v):
    _prompt(v)
    text = _load(v, "--slow prog")
    assert "loaded $2000-$201e" in text and "Fast-" not in text, \
        "load --slow did not use the standard path:\n%s" % text
    assert _loaded(v), "the program is not at $2000"


def test_load_wildcard_stays_fast(v):
    _prompt(v)
    text = _load(v, "pr*")
    assert "Fast-loaded $2000-$201e" in text, \
        "the drive loader did not match pr*:\n%s" % text
    assert _loaded(v), "the program is not at $2000"


def test_load_missing_file_reports_the_drives_reason(v):
    _prompt(v)
    text = _load(v, "zznope")
    assert "62" in text, "no drive status for a missing file:\n%s" % text
    assert "fast load" not in text, \
        "the fast attempt's failure leaked out:\n%s" % text


def test_load_skips_the_fast_path_for_a_seq_file(v):
    """`doc` is SEQ. The drive loader takes only closed PRGs, so the fast
    path must not claim it; what happens next is the drive's own business."""
    _prompt(v)
    text = _load(v, "doc")
    assert "Fast-loaded" not in text and "fast load" not in text, \
        "a SEQ file went down the fast path:\n%s" % text


def test_load_rejects_an_unknown_option(v):
    _prompt(v)
    text = _load(v, "--fast prog")
    assert "usage: load [--slow] <name>" in text, \
        "an unknown option was not refused:\n%s" % text
