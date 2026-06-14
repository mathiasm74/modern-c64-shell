"""run <name>: fast-load a program and run it.

`run <name>` loads the named PRG over the Epyx fast path (exactly like
`fload`) and then hands it to a real stock environment to RUN -- bare `run`
still re-runs whatever was loaded last. Both the Epyx transfer and the stock
swap are hardware-only (VICE's 1541 can't model Epyx mode, and there's no One
ROM to swap into), so the load-and-run itself is hardware-tested -- the same
boundary as `fload`/`run`.

What IS observable here is the resident routing: a bare `run` with nothing
loaded reports it, and `run <name>` enters the fast-load path (the emulated
1541 isn't Epyx-aware, so the ready-for-header handshake times out and the
load is reported failed) and leaves the shell alive -- proving the filename
argument is wired to the loader rather than the "nothing loaded" path.

This lives in its own module because the fast-load attempt M-E's the Epyx
install stub into the drive, which would dirty a VICE shared by other tests.
"""

VICE_DISK = "data/test.d64"

CR = 0x0D


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [CR])
    v.write_byte(0x00C6, len(text) + 1)


def _wait_any(v, needles, tries=12, chunk=0.5):
    for _ in range(tries):
        v.run_for(chunk)
        t = v.screen_text()
        if any(n in t for n in needles):
            return True
    return False


def test_run_no_arg_reports_nothing_loaded(v):
    v.run_for(0.3)
    _type(v, "run")
    assert _wait_any(v, ["nothing loaded"]), \
        "bare run with nothing loaded should say so\n%s" % v.screen_text()


def test_run_name_enters_fastload_and_survives(v):
    # The emulated 1541 isn't Epyx-aware, so the fast-load handshake times out
    # and the load is reported failed. The point is the name routed into the
    # fast-load path (NOT "nothing loaded") and the shell came back.
    v.run_for(0.3)
    _type(v, "run prog")
    assert _wait_any(v, ["fast load not supported", "fast load failed",
                         "not present", "read error"]), \
        "run <name> did not enter the fast-load path\n%s" % v.screen_text()
    assert "nothing loaded" not in v.screen_text(), \
        "run <name> wrongly took the no-program path\n%s" % v.screen_text()
    # shell still alive after the failed fast load
    _type(v, "ver")
    assert _wait_any(v, ["C64 Shell ROM v"]), \
        "shell unresponsive after run <name>\n%s" % v.screen_text()
