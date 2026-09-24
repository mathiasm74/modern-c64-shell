"""Drive commands: dos / init / validate / format, and the @ wedge.

`dos <cmd>` sends any drive (CBM DOS) command on channel 15 and prints the
drive's reply as `status` does; `@<cmd>` is the JiffyDOS spelling of the same
thing (@i, @v, @n:name,id, @"s:file"). init, validate and format are named
shortcuts; format asks before erasing. They run against a scratch copy of the
fixture, since validate and format write to it.
"""

import os
import shutil

from lib.overlays import seed_files, seed_disk_bank

_HERE = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_dos.d64"))
VICE_DISK = "data/_scratch_dos.d64"

CR = 0x0D
CLEAR = 0x93


def _type(v, text, clear=True):
    codes = ([CLEAR] if clear else []) + [ord(c) for c in text] + [CR]
    while codes:
        chunk, codes = codes[:8], codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        for _ in range(20):
            v.run_for(0.05)
            if v.read_byte(0x00C6) == 0:
                break


def _key(v, c):
    v.write_memory(0x0277, [ord(c)])
    v.write_byte(0x00C6, 1)
    v.run_for(0.3)


def _wait(v, needle, tries=60, chunk=0.3):
    for _ in range(tries):
        if needle in v.screen_text():
            return True
        v.run_for(chunk)
    return needle in v.screen_text()


def _after(v, marker):
    """The rows below the LAST one containing `marker`. A CLR typed into the
    keyboard buffer does not clear the screen, so earlier tests' output is
    still there above it."""
    rows = v.screen_rows()
    at = max(i for i, r in enumerate(rows) if marker in r)
    return "\n".join(rows[at + 1:])


def _wait_after(v, marker, needle, tries=60):
    """_wait, but only for output below `marker` -- the same prompt from an
    earlier test is still on screen and would satisfy a plain _wait."""
    for _ in range(tries):
        if any(marker in r for r in v.screen_rows()) and needle in _after(v, marker):
            return True
        v.run_for(0.3)
    return False


def _ready(v):
    assert _wait(v, "8>", tries=80), "no prompt\n%s" % v.screen_text()


def _run(v, cmd, want):
    seed_files(v)
    _type(v, cmd)
    assert _wait_after(v, "8> " + cmd, want), \
        "%r: no %r\n%s" % (cmd, want, v.screen_text())


def test_dos_sends_a_command_and_prints_the_reply(v):
    _ready(v)
    _run(v, "dos i", "00 OK")


def test_dos_without_a_command_prints_usage(v):
    _ready(v)
    _run(v, "dos", "usage: dos")


def test_init_and_validate(v):
    _ready(v)
    _run(v, "init", "00 OK")
    _run(v, "validate", "00 OK")


def test_the_at_wedge_sends_drive_commands(v):
    """@i, and a quoted @"..." as JiffyDOS writes it -- here a scratch, whose
    reply is 01 FILES SCRATCHED with the count."""
    _ready(v)
    _run(v, "@i", "00 OK")
    _run(v, '@"s:doc"', "01 FILES SCRATCHED")


def test_the_other_at_wedges_still_work(v):
    _ready(v)
    _run(v, "@", "00")                      # bare @ is still status
    seed_disk_bank(v)
    _type(v, "@$")
    # Wait for THIS listing to end: seeding the next test's bank over $A000
    # while the disk bank is still printing would run half of each.
    assert _wait_after(v, "8> @$", "BLOCKS FREE"), "@$ is no longer the directory"
    assert _wait_after(v, "BLOCKS FREE", "8>"), "the listing did not finish"


def test_format_asks_and_n_keeps_the_disk(v):
    _ready(v)
    seed_files(v)
    _type(v, "format blank")
    assert _wait_after(v, "format blank", "erase the disk in 8? (y/n)"), \
        v.screen_text()
    _key(v, "n")
    v.run_for(1.0)
    assert "00 OK" not in _after(v, "(y/n) n"), "format ran after n"
    seed_disk_bank(v)
    _type(v, "dir")
    assert _wait_after(v, "8> dir", "BLOCKS FREE"), v.screen_text()
    assert "BLANK" not in _after(v, "8> dir"), "the disk was renamed after n"


def test_zz_format_y_quick_formats_with_a_spaced_name(v):
    """Without an id it is a quick format: new name, empty directory. The two
    words are joined into one name. (Erases the scratch disk, so it runs last;
    the runner sorts by name.)"""
    _ready(v)
    seed_files(v)
    _type(v, "format my disk")
    assert _wait_after(v, "format my disk", "(y/n)"), v.screen_text()
    _key(v, "y")
    assert _wait_after(v, "format my disk", "00 OK", tries=120), \
        "quick format did not report 00 OK\n%s" % v.screen_text()
    seed_disk_bank(v)
    _type(v, "dir")
    assert _wait_after(v, "8> dir", "BLOCKS FREE"), v.screen_text()
    txt = _after(v, "8> dir")
    assert "MY DISK" in txt, "the new name is not in the header\n%s" % txt
    assert "README" not in txt and "readme" not in txt, \
        "files survived the format\n%s" % txt
