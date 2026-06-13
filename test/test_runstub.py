"""The `run` autostart stub, validated against the real stock ROMs.

`run` swaps the One ROM to stock and autostarts a planted stub (run_stub in
c_io.s) that starts a loaded program -- BASIC via init-without-NEW + RUN, ML
via JMP through the load address. The swap itself is hardware-only, but the
STUB runs in the stock environment, which we *can* reproduce in VICE by
booting it with the stock ROMs and jumping straight to the stub (no swap).

Crucially this exercises the stub after a DIRTY zero page -- the real
hazard, since on hardware the stub inherits our shell's cc65 leftovers
rather than a clean boot. That's exactly the condition that made an earlier
no-RAMTAS version fail unpredictably.

Skips when stock-roms/ isn't present (user-supplied, gitignored), so it runs
locally but never blocks CI.
"""

import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.join(_HERE, "..")
_KERNAL = os.path.join(_ROOT, "stock-roms", "kernal.901227-03.bin")
_BASIC = os.path.join(_ROOT, "stock-roms", "basic.901226-01.bin")
_KBIN = os.path.join(_ROOT, "build", "kernal.bin")
_LABELS = os.path.join(_ROOT, "build", "labels.txt")

_HAVE_STOCK = os.path.exists(_KERNAL) and os.path.exists(_BASIC)


def _stub_bytes():
    lab = {}
    for line in open(_LABELS):
        p = line.split()
        if len(p) >= 3 and p[0] == "al":
            lab[p[2].lstrip(".")] = int(p[1], 16) & 0xFFFF
    s, e = lab["_run_stub"], lab["_run_stub_end"]
    rom = open(_KBIN, "rb").read()
    return rom[s - 0xE000:e - 0xE000]


def _stock_vice():
    import sys
    sys.path.insert(0, os.path.join(_HERE, "lib"))
    from vice import Vice
    return Vice(kernal=_KERNAL, basic=_BASIC)


def test_run_stub_runs_basic_program(v):
    # `v` (our-ROM VICE) is unused; the stub must run under the STOCK ROMs.
    if not _HAVE_STOCK:
        return  # skip: no user-supplied stock ROMs
    stub = list(_stub_bytes())
    # 1 PRINT"OK"
    prog = [0x0B, 0x08, 0x01, 0x00, 0x99, 0x22, 0x4F, 0x4B, 0x22, 0x00, 0x00, 0x00]
    with _stock_vice() as sv:
        sv.run_for(2.0)
        # dirty the machine the way our shell leaves it
        sv.write_memory(0x0002, [0xAA] * 254)
        sv.write_memory(0x0200, [0x55] * 0x100)
        sv.write_memory(0x0300, [0x33] * 0x100)
        sv.write_memory(0x0801, prog)
        sv.write_memory(0xCFF8, [0x01, 0x08, 0x0D, 0x08])  # load $0801, end $080D
        sv.write_memory(0xCFFC, [0x00])                    # mode 0 = RUN
        sv.write_memory(0xCF00, stub)
        sv.run_at(0xCF00, 1.5)
        rows = [r.strip() for r in sv.screen_text().split("\n")]
        assert "ok" in rows, \
            "stub did not RUN the BASIC program\n%s" % sv.screen_text()


def test_run_stub_relinks_broken_link(v):
    # A real PRG often carries forward-link bytes that don't match the load
    # address (BASIC's own LOAD rebuilds them). Our stub must do the same via
    # LINKPRG, or RUN/LIST see a broken line chain -- this is what made FB throw
    # ?SYNTAX ERROR. Give the program a DELIBERATELY broken link ($FFFF) and
    # check the stub both rebuilds it and still RUNs the program.
    if not _HAVE_STOCK:
        return
    stub = list(_stub_bytes())
    # 1 PRINT"OK", but the forward link is garbage ($FFFF) instead of $080B.
    prog = [0xFF, 0xFF, 0x01, 0x00, 0x99, 0x22, 0x4F, 0x4B, 0x22, 0x00, 0x00, 0x00]
    with _stock_vice() as sv:
        sv.run_for(2.0)
        sv.write_memory(0x0002, [0xAA] * 254)
        sv.write_memory(0x0300, [0x33] * 0x100)
        sv.write_memory(0x0801, prog)
        sv.write_memory(0xCFF8, [0x01, 0x08, 0x0D, 0x08])  # load $0801, end $080D
        sv.write_memory(0xCFFC, [0x00])                    # mode 0 = RUN
        sv.write_memory(0xCF00, stub)
        sv.run_at(0xCF00, 1.5)
        link = list(sv.read_memory(0x0801, 2))
        assert link == [0x0B, 0x08], \
            "LINKPRG did not rebuild the broken line link: %r" % (link,)
        rows = [r.strip() for r in sv.screen_text().split("\n")]
        assert "ok" in rows, \
            "stub did not RUN after relinking\n%s" % sv.screen_text()


def test_run_stub_ready_mode_does_not_autorun(v):
    # mode 1 (used by `runstock` when a program is loaded) sets the program up
    # like LOAD but stops at BASIC READY. instead of RUNning, so it can be
    # LISTed by hand. Verify READY. shows, the link is rebuilt, and the program
    # did NOT auto-run.
    if not _HAVE_STOCK:
        return
    stub = list(_stub_bytes())
    prog = [0xFF, 0xFF, 0x01, 0x00, 0x99, 0x22, 0x4F, 0x4B, 0x22, 0x00, 0x00, 0x00]
    with _stock_vice() as sv:
        sv.run_for(2.0)
        sv.write_memory(0x0002, [0xAA] * 254)
        sv.write_memory(0x0300, [0x33] * 0x100)
        sv.write_memory(0x0801, prog)
        sv.write_memory(0xCFF8, [0x01, 0x08, 0x0D, 0x08])  # load $0801, end $080D
        sv.write_memory(0xCFFC, [0x01])                    # mode 1 = READY.
        sv.write_memory(0xCF00, stub)
        sv.run_at(0xCF00, 1.5)
        link = list(sv.read_memory(0x0801, 2))
        assert link == [0x0B, 0x08], \
            "LINKPRG did not rebuild the link in READY mode: %r" % (link,)
        rows = [r.strip() for r in sv.screen_text().split("\n")]
        assert any("ready" in r for r in rows), \
            "stub did not drop to BASIC READY.\n%s" % sv.screen_text()
        assert "ok" not in rows, \
            "READY mode must not auto-run the program\n%s" % sv.screen_text()


def test_run_stub_starts_machine_code(v):
    if not _HAVE_STOCK:
        return
    stub = list(_stub_bytes())
    # $2000: LDA #$07 / STA $D020 / JMP $2005  (border 7, spin)
    ml = [0xA9, 0x07, 0x8D, 0x20, 0xD0, 0x4C, 0x05, 0x20]
    with _stock_vice() as sv:
        sv.run_for(2.0)
        sv.write_memory(0x0002, [0xAA] * 254)
        sv.write_memory(0x0300, [0x33] * 0x100)
        sv.write_memory(0x2000, ml)
        sv.write_memory(0xCFF8, [0x00, 0x20, 0x00, 0x20])  # load $2000 (ML)
        sv.write_memory(0xCF00, stub)
        sv.run_at(0xCF00, 1.0)
        border = sv.read_byte(0xD020) & 0x0F
        assert border == 0x07, \
            "stub did not start the ML program (border=$%02X)" % border
