"""The run command: load a program and start it like SYS (Phase 6/8).

run calls the loaded program as a subroutine, so a program that ends in RTS
returns to the shell. The fixture (test/data/test.d64 "prog") loads at $2000,
prints "hello from prog" via CHROUT, then RTSes -- so a successful run shows
the message and the shell regains the prompt. Its own module keeps it isolated
in case a future test program takes over the machine instead of returning.
"""

VICE_DISK = "data/test.d64"


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [0x0D])
    v.write_byte(0x00C6, len(text) + 1)


def _wait_for(v, needle, tries=8, chunk=0.5):
    for _ in range(tries):
        v.run_for(chunk)
        if needle in v.screen_text():
            return True
    return False


def test_run_prints_and_returns(v):
    v.run_for(0.3)
    _type(v, "load prog")
    if not _wait_for(v, "loaded $"):
        raise AssertionError("load never completed\n%s" % v.screen_text())

    _type(v, "run")
    assert _wait_for(v, "hello from prog"), \
        "run did not print the program's output\n%s" % v.screen_text()

    # The program ended in RTS, so the shell must have regained control --
    # a follow-up command still runs.
    _type(v, "ver")
    assert _wait_for(v, "C64 Shell ROM v0.1"), \
        "shell did not return to the prompt after the program RTS'd\n%s" % v.screen_text()
