"""rm scratches a file from the drive (Phase 8).

rm writes "S0:<name>" to the command channel. That MUTATES the disk, so this
module works on a throwaway copy of test.d64 (made fresh at import) rather
than the committed fixture. The scratch copy is gitignored.
"""

import os
import shutil

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_rm.d64"))

VICE_DISK = "data/_scratch_rm.d64"


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [0x0D])
    v.write_byte(0x00C6, len(text) + 1)


def _ls(v):
    """Clear the screen, run ls, and wait for it to finish."""
    v.write_memory(0x0277, [0x93] + [ord("l"), ord("s")] + [0x0D])
    v.write_byte(0x00C6, 4)
    for _ in range(10):
        v.run_for(0.6)
        if "BLOCKS FREE" in v.screen_text():
            return True
    return False


def test_rm_scratches_file(v):
    v.run_for(0.3)
    assert _ls(v), "ls did not complete"
    assert "PROG" in v.screen_text(), "fixture should start with PROG"

    _type(v, "rm prog")
    v.run_for(1.0)

    assert _ls(v), "ls did not complete after rm"
    txt = v.screen_text()
    assert "PROG" not in txt, "rm did not scratch PROG\n%s" % txt
    assert "README" in txt, "rm removed the wrong file"
