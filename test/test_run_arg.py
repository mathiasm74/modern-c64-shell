"""run <name>: fast-load a program and run it.

`run <name>` loads the named PRG over the Epyx fast path (exactly like
`fload`) and then hands it to a real stock environment to RUN -- bare `run`
still re-runs whatever was loaded last.

Only the NO-ARGUMENT case lives here, and that is deliberate. `run <name>`
now genuinely fast-loads under VICE (src/drive1541.s), so it goes on to the
stock swap -- which is inert without a One ROM and leaves the machine in the
documented CBM80 reboot loop. That would poison anything sharing this VICE,
so it has a module of its own: test_run_fastload.py.

The fast-load path is in the DISK BANK now (docs/ROM-EXPANSION.md), so the
tests seed it first -- see seed_disk_bank. Without it `run <name>` correctly
reports "disk bank unavailable", which is a different path than the one under
test here.

This lives in its own module because the fast-load attempt M-E's the Epyx
install stub into the drive, which would dirty a VICE shared by other tests.
"""

from lib.overlays import seed_disk_bank

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


def _at_prompt(v, tries=20):
    """Wait for a live prompt. `run <name>` reboots the machine in VICE (the
    stock swap falls through to the reset vector), so a test that follows one
    cannot assume the shell it was given is still the shell it has."""
    for _ in range(tries):
        v.run_for(0.3)
        if "8>" in v.screen_text():
            return True
    return False


def test_run_no_arg_reports_nothing_loaded(v):
    assert _at_prompt(v), "no prompt to type at\n%s" % v.screen_text()
    _type(v, "run")
    assert _wait_any(v, ["nothing loaded"]), \
        "bare run with nothing loaded should say so\n%s" % v.screen_text()
