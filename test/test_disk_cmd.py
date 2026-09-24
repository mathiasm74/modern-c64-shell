"""`disk <status|init|validate|format>`: the drive's housekeeping under one name.

cmd_disk (shell.c) re-dispatches `disk X args` as `X args`; the four are
ordinary files-bank commands in the dispatch table's unlisted tail. Bare `disk`
or an unknown subcommand lists them. Runs on a scratch copy, since validate
writes the disk.
"""

import os
import shutil

from lib.overlays import seed_files

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_diskcmd.d64"))
VICE_DISK = "data/_scratch_diskcmd.d64"

CR = 0x0D


def _type(v, text):
    codes = [ord(c) for c in text] + [CR]
    while codes:
        chunk, codes = codes[:8], codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        for _ in range(20):
            v.run_for(0.05)
            if v.read_byte(0x00C6) == 0:
                break


def _after(v, marker):
    rows = v.screen_rows()
    hits = [i for i, r in enumerate(rows) if marker in r]
    return "\n".join(rows[hits[-1] + 1:]) if hits else ""


def _idle(v, tries=60):
    """A bare prompt on the last non-blank row: nothing is still running, so
    seeding a bank over $A000 is safe (see test_dos._idle)."""
    for _ in range(tries):
        rows = [r.rstrip() for r in v.screen_rows() if r.strip()]
        if rows and rows[-1] == "8>":
            return
        v.run_for(0.3)
    raise AssertionError("the shell never went idle\n%s" % v.screen_text())


def _run(v, cmd, want, tries=60):
    """Type cmd and wait for `want` BELOW its own row: the screen keeps the
    earlier tests' output (a typed CLR does not clear it)."""
    _idle(v)
    seed_files(v)
    _type(v, cmd)
    for _ in range(tries):
        if want in _after(v, "8> " + cmd):
            return _after(v, "8> " + cmd)
        v.run_for(0.3)
    raise AssertionError("%r: no %r\n%s" % (cmd, want, v.screen_text()))


def _ready(v):
    for _ in range(80):
        if "8>" in v.screen_text():
            return
        v.run_for(0.3)
    raise AssertionError("no prompt\n%s" % v.screen_text())


def test_bare_disk_lists_the_subcommands(v):
    _ready(v)
    out = _run(v, "disk", "format")
    for sub in ("status", "init", "validate", "format"):
        assert sub in out, "bare disk does not list %s\n%s" % (sub, out)


def test_unknown_subcommand_lists_them_too(v):
    _ready(v)
    out = _run(v, "disk bogus", "validate")
    assert "Command not found" not in out


def test_disk_init_then_status(v):
    _ready(v)
    _run(v, "disk init", "00 OK")
    _run(v, "disk status", "00 OK")


def test_disk_validate(v):
    _ready(v)
    _run(v, "disk validate", "00 OK")


def test_disk_format_passes_its_arguments_on(v):
    """`disk format` without a name is format's own usage (argv moved along);
    with one it asks, and n leaves the disk alone."""
    _ready(v)
    _run(v, "disk format", "usage: format")
    _run(v, "disk format blank", "(y/n)")
    v.write_memory(0x0277, [ord("n")])
    v.write_byte(0x00C6, 1)
    v.run_for(1.0)
    assert "00 OK" not in _after(v, "(y/n) n"), "disk format ran after n"
