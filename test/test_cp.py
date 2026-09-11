"""cp copies a file on the drive (Phase 8).

cp reads the source into RAM and writes it to a new PRG. Like rm it MUTATES
the disk, so this works on a throwaway copy of test.d64 (made fresh at
import; gitignored). It copies "readme" to "r2" and checks the new file
exists and its payload is byte-identical.
"""

import os
import shutil

from lib.overlays import seed_files, seed_disk_bank

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_cp.d64"))

VICE_DISK = "data/_scratch_cp.d64"

CR = 0x0D
CLEAR = 0x93


def _ch(s):
    return [ord(c) for c in s]


def _ls(v):
    seed_disk_bank(v)              # dir is an overlay
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


def _typeln(v, text):
    """Type a whole line through the 10-byte buffer, chunked, then RETURN."""
    codes = _ch(text) + [CR]
    while codes:
        chunk, codes = codes[:8], codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        v.run_for(0.4)


def _await(v, needle, tries=20):
    for _ in range(tries):
        if needle in v.screen_text():
            return True
        v.run_for(0.6)
    return False


def test_spaced_filenames_end_to_end(v):
    # Quoted names survive the parser and the IEC layer end to end: copy prog
    # to a spaced name, load it back quoted AND via the /wedge (which quotes
    # the whole rest of the line itself), then scratch it.
    v.run_for(0.3)
    seed_files(v)
    _typeln(v, 'cp prog "my prog"')
    assert _await(v, "copied"), "cp to a spaced name failed: %r" % v.screen_text()
    _typeln(v, 'clear')
    # cp is a FILES-bank command and load a DISK-bank one; only one bank can be
    # seeded at a time in VICE (they all link to $A000), so swap between them.
    seed_disk_bank(v)
    _typeln(v, 'load "my prog"')
    assert _await(v, "loaded $2000"), \
        "quoted load of the spaced file failed: %r" % v.screen_text()
    _typeln(v, 'clear')
    _typeln(v, '/my prog')
    assert _await(v, "loaded $2000"), \
        "/wedge load of the spaced file failed: %r" % v.screen_text()
    seed_files(v)
    _typeln(v, 'rm "my prog"')
    _typeln(v, 'clear')
    seed_disk_bank(v)
    _typeln(v, 'load "my prog"')
    # load now surfaces the drive's error channel: a missing file is the 1541's
    # "62 FILE NOT FOUND" (uppercase) rather than our old lowercase message.
    assert _await(v, "FILE NOT FOUND"), \
        "spaced file was not scratched: %r" % v.screen_text()
