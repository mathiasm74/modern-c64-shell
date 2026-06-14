"""rm scratches a file from the drive (Phase 8).

rm writes "S0:<name>" to the command channel. That MUTATES the disk, so this
module works on a throwaway copy of test.d64 (made fresh at import) rather
than the committed fixture. The scratch copy is gitignored.
"""

import os
import shutil

from lib.overlays import seed_files, seed_dir

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_rm.d64"))

VICE_DISK = "data/_scratch_rm.d64"


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [0x0D])
    v.write_byte(0x00C6, len(text) + 1)


def _ls(v):
    seed_dir(v)              # dir is an overlay
    """Clear the screen, run dir (the full listing), wait for it to finish."""
    v.write_memory(0x0277, [0x93] + [ord(c) for c in "dir"] + [0x0D])
    v.write_byte(0x00C6, 5)
    for _ in range(20):
        v.run_for(0.6)
        if "BLOCKS FREE" in v.screen_text():
            return True
    return False


def test_rm_scratches_file(v):
    v.run_for(0.3)
    assert _ls(v), "ls did not complete"
    assert "PROG" in v.screen_text(), "fixture should start with PROG"

    seed_files(v)               # rm is in the files overlay
    _type(v, "rm prog")
    v.run_for(1.0)

    assert _ls(v), "ls did not complete after rm"
    txt = v.screen_text()
    assert "PROG" not in txt, "rm did not scratch PROG\n%s" % txt
    assert "README" in txt, "rm removed the wrong file"


def test_rm_missing_reports_not_found(v):
    # Scratching a name that doesn't exist returns "01,FILES SCRATCHED,00"
    # (0 files) -- rm reports that as "rm: not found" rather than silently
    # "succeeding". (zznope never exists, so this is order-independent.)
    seed_files(v)
    v.write_memory(0x0277, [0x93])              # clear
    v.write_byte(0x00C6, 1)
    v.run_for(0.2)
    _type(v, "rm zznope")                       # 9 chars + CR = 10 (fits buffer)
    for _ in range(12):
        v.run_for(0.5)
        if "not found" in v.screen_text():
            break
    assert "rm: not found" in v.screen_text(), \
        "rm of a missing file should report not found\n%s" % v.screen_text()
