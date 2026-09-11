"""rm scratches a file from the drive (Phase 8).

rm writes "S0:<name>" to the command channel. That MUTATES the disk, so this
module works on a throwaway copy of test.d64 (made fresh at import) rather
than the committed fixture. The scratch copy is gitignored.
"""

import os
import shutil

from lib.overlays import seed_files, seed_disk_bank

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_rm.d64"))

VICE_DISK = "data/_scratch_rm.d64"


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [0x0D])
    v.write_byte(0x00C6, len(text) + 1)


def _ls(v):
    seed_disk_bank(v)              # dir is an overlay
    """Clear the screen, run dir (the full listing), wait for it to finish."""
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


def test_rm_invalidates_tab_cache_only_on_success(v):
    # rm invalidates the completion cache ($CE00) only when it actually removes
    # a file -- a directory that changed makes the cached names stale. A FAILED
    # rm (nothing matched) left the directory untouched, so the cache (and the
    # path pwd reports) must survive: clearing it there is the "an error forgets
    # the data tab-completion/pwd need" bug.
    seed_files(v)
    v.write_byte(0xCE00, 1)                     # pretend a listing filled it
    _type(v, "rm zznope")                       # no such file -> "rm: not found"
    for _ in range(20):
        if "not found" in v.screen_text():
            break
        v.run_for(0.4)
    assert v.read_byte(0xCE00) == 1, \
        "a failed rm wrongly invalidated the completion cache"

    v.write_byte(0xCE00, 1)
    _type(v, "rm doc")                          # a real file (SEQ) -> scratched
    for _ in range(20):
        v.run_for(0.4)
        if v.read_byte(0xCE00) == 0:
            break
    assert v.read_byte(0xCE00) == 0, \
        "a successful rm did not invalidate the completion cache"
