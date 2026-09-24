"""help lists the commands to use, not every row of the dispatch table.

`fload` (the Epyx fast path alone -- `load` is fast by default and falls back
by itself) and `dev` (an alias of `device`) sit in the table's unlisted tail:
they still run, but help leaves them out.
"""

import re

from lib.overlays import seed_files, seed_disk_bank

VICE_DISK = "data/test.d64"

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
    v.run_for(0.5)


def _wait(v, needle, tries=60):
    for _ in range(tries):
        if needle in v.screen_text():
            return True
        v.run_for(0.2)
    return needle in v.screen_text()


def test_help_leaves_out_the_unlisted_commands(v):
    assert _wait(v, "8>", tries=80)
    seed_files(v)
    _type(v, "help")
    assert _wait(v, "recalls"), "help did not finish\n%s" % v.screen_text()
    rows = v.screen_rows()
    top = max(i for i, r in enumerate(rows) if "Commands:" in r)
    words = set(re.findall(r"[a-z]+", " ".join(rows[top + 1:])))
    for gone in ("fload", "dev"):
        assert gone not in words, "help still lists %s" % gone
    for name in ("load", "device", "dos", "format", "init", "validate", "ver"):
        assert name in words, "help no longer lists %s" % name


def test_unlisted_commands_still_run(v):
    assert _wait(v, "8>", tries=80)
    seed_files(v)
    _type(v, "dev")                         # device with no argument: the device
    seed_disk_bank(v)
    _type(v, "fload")                       # fload with no name: its usage
    txt = v.screen_text()
    assert "Command not found" not in txt, \
        "an unlisted command no longer dispatches\n%s" % txt
