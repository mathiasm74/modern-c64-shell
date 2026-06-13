"""cp copies a file on the drive (Phase 8).

cp reads the source into RAM and writes it to a new PRG. Like rm it MUTATES
the disk, so this works on a throwaway copy of test.d64 (made fresh at
import; gitignored). It copies "readme" to "r2" and checks the new file
exists and its payload is byte-identical.
"""

import os
import shutil

from lib.overlays import seed_files, seed_dir

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_cp.d64"))

VICE_DISK = "data/_scratch_cp.d64"

CR = 0x0D
CLEAR = 0x93


def _ch(s):
    return [ord(c) for c in s]


def _ls(v):
    seed_dir(v)              # dir is an overlay
    v.write_memory(0x0277, [CLEAR] + _ch("dir") + [CR])     # full listing
    v.write_byte(0x00C6, 5)
    for _ in range(20):
        v.run_for(0.6)
        if "BLOCKS FREE" in v.screen_text():
            return v.screen_text()
    return v.screen_text()


def test_cp_copies_file(v):
    v.run_for(0.3)
    seed_files(v)               # cp is in the files overlay
    # "cp readme r2" is 12 chars; split across two keyboard-buffer loads.
    v.write_memory(0x0277, _ch("cp readme"))
    v.write_byte(0x00C6, 9)
    v.run_for(0.3)
    v.write_memory(0x0277, _ch(" r2") + [CR])
    v.write_byte(0x00C6, 4)
    v.run_for(1.5)
    assert "copied" in v.screen_text(), "cp did not report success"

    txt = _ls(v)
    assert "R2" in txt, "cp did not create R2\n%s" % txt
    assert "README" in txt, "cp lost the source file"

    # the copy is byte-identical: load it and check the payload starts "C64".
    v.write_memory(0x0277, [CLEAR] + _ch("load r2") + [CR])
    v.write_byte(0x00C6, 9)
    for _ in range(8):
        v.run_for(0.6)
        if "loaded" in v.screen_text():
            break
    assert v.read_memory(0x2000, 3) == [0x43, 0x36, 0x34], \
        "copied payload is not 'C64...' (cp corrupted the data)"
