"""mv renames a file on the drive (Phase 8).

mv writes "R0:<new>=<old>" to the command channel -- the same path rm uses to
scratch a file. That MUTATES the disk, so this works on a throwaway copy of
test.d64 (made fresh at import) rather than the committed fixture. The
scratch copy is gitignored.
"""

import os
import shutil

from lib.overlays import seed_files, seed_disk_bank

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_mv.d64"))

VICE_DISK = "data/_scratch_mv.d64"


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [0x0D])
    v.write_byte(0x00C6, len(text) + 1)


def _ls(v):
    seed_disk_bank(v)              # dir is an overlay
    """Clear the screen, run dir, wait for it to finish."""
    # `clear` as a COMMAND: since v0.1.57 the CLR keystroke only wipes the
    # input line, and this test needs the previous listing gone ("PROG not
    # in screen" must mean the file is gone, not that it scrolled up).
    v.write_memory(0x0277, [ord(c) for c in "clear"] + [0x0D]
                   + [ord(c) for c in "dir"] + [0x0D])
    v.write_byte(0x00C6, 10)
    for _ in range(20):
        v.run_for(0.6)
        if "BLOCKS FREE" in v.screen_text():
            return True
    return False


def test_mv_renames_file(v):
    v.run_for(0.3)
    assert _ls(v), "initial dir did not complete"
    assert "PROG" in v.screen_text(), "fixture should start with PROG"

    # "mv prog x" is 9 chars + CR = 10, fits the keyboard buffer.
    seed_files(v)               # mv is in the files overlay
    _type(v, "mv prog x")
    v.run_for(1.0)

    assert _ls(v), "dir did not complete after mv"
    txt = v.screen_text()
    # The drive folds filenames to uppercase and dir wraps names in quotes
    # ("X"); the original "PROG" should be gone, but the other files remain.
    assert '"X"' in txt, "mv did not produce a file named X\n%s" % txt
    assert "PROG" not in txt, "mv did not move PROG away\n%s" % txt
    assert "README" in txt, "mv removed the wrong file"


def test_mv_missing_reports_error(v):
    # Renaming a source that doesn't exist returns "62,FILE NOT FOUND" -- mv
    # surfaces it as "mv: FILE NOT FOUND" instead of silently doing nothing.
    # (zz never exists, so this is order-independent and mutates nothing.)
    seed_files(v)
    v.write_memory(0x0277, [0x93])              # clear
    v.write_byte(0x00C6, 1)
    v.run_for(0.2)
    _type(v, "mv zz z2")                        # 8 chars + CR
    for _ in range(12):
        v.run_for(0.5)
        if "mv:" in v.screen_text():
            break
    txt = v.screen_text()
    assert "mv:" in txt and "NOT FOUND" in txt, \
        "mv of a missing source should report the drive error\n%s" % txt
