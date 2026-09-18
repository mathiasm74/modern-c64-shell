"""`run <name>` routes its argument into the fast-load path.

Its own module because the moment the drive-side loader is ungated this test
ends in the stock swap, which is inert in VICE: the launcher finds no One ROM,
falls through to jmp ($FFFC), and Tardis's reset re-detects the CBM80 `run`
just planted -- the documented boot loop. Anything sharing this VICE would
then meet a rebooting machine.

So the assertion is on MEMORY, not the screen: the loop wipes the display but
the program stays where the loader put it. That is the better check anyway --
it proves the bytes arrived, not merely that a message was printed.

This used to assert the OPPOSITE. VICE's 1541 could not be driven in Epyx mode
because we had no drive-side code to give it, so `run <name>` was expected to
report a timeout. src/drive1541.s changed that.
"""

from lib.overlays import seed_disk_bank

VICE_DISK = "data/test.d64"

CR = 0x0D

# test/data/test.d64's `prog`: 31 bytes at $2000.
PROG = [0xA2, 0x00, 0xBD, 0x0E, 0x20, 0xF0, 0x06, 0x20]


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [CR])
    v.write_byte(0x00C6, len(text) + 1)


def test_run_name_fast_loads_the_program(v):
    for _ in range(20):
        v.run_for(0.3)
        if "8>" in v.screen_text():
            break
    else:
        raise AssertionError("no prompt:\n%s" % v.screen_text())

    v.write_memory(0x2000, [0] * 8)      # so a stale image cannot pass this
    seed_disk_bank(v)
    _type(v, "run prog")
    for _ in range(20):
        v.run_for(0.5)
        if list(v.read_memory(0x2000, 8)) == PROG:
            break
    got = list(v.read_memory(0x2000, 8))
    assert got == PROG, (
        "run <name> did not fast-load the program to $2000\n"
        "  got  %s\n  want %s\n%s"
        % (" ".join("$%02X" % b for b in got),
           " ".join("$%02X" % b for b in PROG), v.screen_text()))
