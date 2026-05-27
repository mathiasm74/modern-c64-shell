"""The run command: load a program, then jump to it (Phase 6).

run hands the whole machine to the loaded program and never returns, so it
gets its own module (its own VICE instance) -- it would leave the shell dead
for any test sharing the machine.

The fixture program (test/data/test.d64 "prog") loads at $2000, stores $42 at
$0340 (the free cassette buffer), then loops forever. So a successful run is
visible as $0340 == $42 with the PC parked in the program.
"""

VICE_DISK = "data/test.d64"


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [0x0D])
    v.write_byte(0x00C6, len(text) + 1)


def test_run_executes_loaded_program(v):
    v.run_for(0.3)
    _type(v, "load prog")
    for _ in range(8):
        v.run_for(0.8)
        if "loaded $" in v.screen_text():
            break
    else:
        raise AssertionError("load never completed\n%s" % v.screen_text())

    _type(v, "run")
    v.run_for(0.5)
    assert v.read_byte(0x0340) == 0x42, \
        "run did not execute the program ($0340 != $42)"
    pc = v.pc()
    # PC should be in the program's loop, or in ROM if we caught a timer IRQ.
    assert (0x2000 <= pc <= 0x2010) or (0xE000 <= pc <= 0xFFFF), \
        "PC $%04X is not in the running program" % pc
