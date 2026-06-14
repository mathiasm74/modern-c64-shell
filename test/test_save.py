"""save: write a memory range to disk as a PRG, and round-trip it via load.

`save <name> <start> <end>` reads bytes straight from memory and writes a new
PRG whose 2-byte load address is <start>, so `load`/`fload` restore it in
place. Like cp/rm it MUTATES the disk, so it runs on a throwaway copy of the
fixture (made fresh at import; gitignored).

The strong check is a round-trip: plant a pattern, save it, wipe it from RAM,
then load it back and confirm the bytes (and the load address) came from disk.
save is in the files overlay, so seed it; load is resident.
"""

import os
import shutil

from lib.overlays import seed_files, seed_dir

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_save.d64"))
VICE_DISK = "data/_scratch_save.d64"

CR = 0x0D
CLEAR = 0x93


def _ch(s):
    return [ord(c) for c in s]


def _type_cmd(v, text, clear=False):
    """Type a command through the 10-byte keyboard buffer (chunked) + RETURN."""
    codes = ([CLEAR] if clear else []) + _ch(text) + [CR]
    while codes:
        chunk, codes = codes[:8], codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        v.run_for(0.3)


def _wait(v, needle, tries=14, chunk=0.5):
    for _ in range(tries):
        v.run_for(chunk)
        if needle in v.screen_text():
            return True
    return False


def test_save_roundtrips_through_load(v):
    v.run_for(0.3)
    seed_files(v)
    # plant a known pattern at $2000 and save it as a PRG loading at $2000
    v.write_memory(0x2000, [0x11, 0x22, 0x33, 0x44])
    _type_cmd(v, "save sv $2000 $2003")
    assert _wait(v, "saved"), "save did not report success\n%s" % v.screen_text()

    # wipe RAM, then load it back -- proves the bytes (and address) are on disk
    v.write_memory(0x2000, [0x00, 0x00, 0x00, 0x00])
    _type_cmd(v, "load sv", clear=True)
    assert _wait(v, "loaded $2000-$2003"), \
        "load did not restore the saved range\n%s" % v.screen_text()
    assert v.read_memory(0x2000, 4) == [0x11, 0x22, 0x33, 0x44], \
        "saved bytes did not round-trip"


def test_saved_file_appears_in_dir(v):
    seed_files(v)
    v.write_memory(0x2100, [0xAB, 0xCD])
    _type_cmd(v, "save sv2 $2100 $2101", clear=True)
    assert _wait(v, "saved"), "second save failed\n%s" % v.screen_text()

    seed_dir(v)                                 # dir is a different overlay
    _type_cmd(v, "dir", clear=True)
    assert _wait(v, "BLOCKS FREE"), "dir did not finish\n%s" % v.screen_text()
    assert "SV2" in v.screen_text(), \
        "saved file missing from the directory\n%s" % v.screen_text()


def test_save_no_args_reports_usage(v):
    _type_cmd(v, "save", clear=True)
    assert _wait(v, "usage: save"), \
        "bare save should print usage\n%s" % v.screen_text()
