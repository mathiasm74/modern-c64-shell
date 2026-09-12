"""The `debug` command: a live view of the raw keyboard matrix (kbdiag.s).

Its own module, because the viewer runs with interrupts off and only exits on a
physical RUN/STOP -- which the harness cannot press (it injects into the keyboard
BUFFER, not the matrix). So it parks the machine, exactly like test_parse_addr's
run_at, and nothing may follow it in the module.

What this can check is the part that rots: that the viewer reads all eight
select lines and renders what it read at the right place. It cannot check a
CLOSED key -- VICE's matrix is only reachable through real key state -- but
all-open is a real assertion: with nothing held, every cell must read open and
every line must report $FF. A transposed grid, a wrong screen address, a bit
walked the wrong way or a broken hex nibble all fail it.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib.overlays import seed_util_bank

GRIDROW = 4                     # must match kbdiag.s
GRIDCOL = 6
CELLGAP = 3
HEXCOL = GRIDCOL + 26


def test_debug_shows_every_select_line_as_open(v):
    seed_util_bank(v)
    v.inject_keys("debug\r")

    rows = None
    for _ in range(25):                 # poll until the viewer has drawn
        v.run_for(0.2)
        rows = v.screen_rows()
        if "keyboard matrix" in rows[0] and rows[GRIDROW].startswith("pa0"):
            break
    else:
        raise AssertionError("the matrix view never drew:\n" + "\n".join(rows[:14]))

    for sel in range(8):
        row = rows[GRIDROW + sel]
        assert row.startswith("pa%d" % sel), \
            "select line %d is labelled %r" % (sel, row[:4])

        # Eight cells, three columns apart. Nothing is held, so all open.
        cells = "".join(row[GRIDCOL + CELLGAP * r] for r in range(8))
        assert cells == "." * 8, \
            "pa%d drew %r, expected 8 open cells (a '*' means a key read as " \
            "CLOSED with nothing pressed -- the bit walk or the address is off)" \
            % (sel, cells)

        # And the raw byte agrees with the cells it was drawn from.
        assert row[HEXCOL:HEXCOL + 2] == "ff", \
            "pa%d reported raw $%s, expected $ff with no key held" \
            % (sel, row[HEXCOL:HEXCOL + 2])
