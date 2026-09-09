"""The stock-BASIC `EXIT` command (basic_exit_wedge in c_io.s).

After `basic`, the run-stub hooks IGONE ($0308) with a wedge so that typing
EXIT at the stock BASIC prompt swaps the One ROM back to Tardis. The swap
itself (rbcp_escape_tramp) is hardware-only -- inert in VICE -- but everything
up to it runs in the real stock environment, which we reproduce here by booting
VICE with the stock ROMs and running the stub (no bank swap), exactly like
test_runstub. We stand a tiny routine in for rbcp_escape_tramp (set the border,
return to READY) so we can SEE the wedge fire.

Skips when stock-roms/ isn't present (user-supplied, gitignored).
"""

import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.join(_HERE, "..")
_KERNAL = os.path.join(_ROOT, "stock-roms", "kernal.901227-03.bin")
_BASIC = os.path.join(_ROOT, "stock-roms", "basic.901226-01.bin")
_KBIN = os.path.join(_ROOT, "build", "kernal.bin")
_LABELS = os.path.join(_ROOT, "build", "labels.txt")

_HAVE_STOCK = os.path.exists(_KERNAL) and os.path.exists(_BASIC)

# Stand-in for the (hardware-only) swap-back: LDA #$05 / STA $D020 / JMP $A474
# -- turn the border yellow, then drop back to READY. so nothing wedges.
_SWAP_STANDIN = [0xA9, 0x05, 0x8D, 0x20, 0xD0, 0x4C, 0x74, 0xA4]


def _labels():
    lab = {}
    for line in open(_LABELS):
        p = line.split()
        if len(p) >= 3 and p[0] == "al":
            lab[p[2].lstrip(".")] = int(p[1], 16) & 0xFFFF
    return lab


def _stub_bytes():
    lab = _labels()
    s, e = lab["_run_stub"], lab["_run_stub_end"]
    rom = open(_KBIN, "rb").read()
    return list(rom[s - 0xE000:e - 0xE000])


def _stock_vice():
    import sys
    sys.path.insert(0, os.path.join(_HERE, "lib"))
    from vice import Vice
    return Vice(kernal=_KERNAL, basic=_BASIC)


def _arm_bare_basic(sv, lab):
    """Boot stock ROMs, run the stub as a bare `basic` (empty program, mode 1),
    and leave it at the READY input loop with the EXIT wedge installed. Returns
    the wedge's expected $0308 address."""
    sv.run_for(2.0)
    # Stand in for rbcp_escape_tramp (the wedge's swap-back target).
    sv.write_memory(lab["rbcp_escape_tramp"], _SWAP_STANDIN)
    sv.write_byte(0xD020, 0x00)                     # border 0; the wedge makes it 5
    sv.write_memory(0x0801, [0, 0, 0])              # empty BASIC program
    sv.write_memory(0xCFF8, [0x01, 0x08, 0x03, 0x08])   # load $0801, end $0803
    sv.write_memory(0xCFFC, [0x01])                 # mode 1 = READY.
    sv.write_memory(0xCFFD, [0x08])                 # device (FA)
    sv.write_memory(0xCF00, _stub_bytes())
    sv.run_at(0xCF00, 1.0)                          # -> READY, waiting for input
    return 0xCF00 + (lab["basic_exit_wedge"] - lab["_run_stub"])


def _feed(sv, codes):
    sv.write_memory(0x0277, codes)
    sv.write_byte(0x00C6, len(codes))


def test_stub_installs_exit_wedge(v):
    if not _HAVE_STOCK:
        return
    lab = _labels()
    with _stock_vice() as sv:
        want = _arm_bare_basic(sv, lab)
        igone = sv.read_byte(0x0308) | (sv.read_byte(0x0309) << 8)
        assert igone == want, \
            "IGONE ($0308=%04X) not hooked to the EXIT wedge (want %04X)" % (igone, want)


def test_exit_swaps_back(v):
    if not _HAVE_STOCK:
        return
    lab = _labels()
    with _stock_vice() as sv:
        _arm_bare_basic(sv, lab)
        _feed(sv, [0x45, 0x58, 0x49, 0x54, 0x0D])   # "EXIT" + RETURN
        for _ in range(12):
            sv.run_for(0.3)
            if (sv.read_byte(0xD020) & 0x0F) == 5:
                return
        assert False, "EXIT did not reach the swap-back (border still $%02X)" % \
            (sv.read_byte(0xD020) & 0x0F)


def test_non_exit_e_line_is_not_intercepted(v):
    # A statement that merely STARTS with 'E' (here "E=1") must fall through the
    # wedge to normal dispatch, not trigger the swap.
    if not _HAVE_STOCK:
        return
    lab = _labels()
    with _stock_vice() as sv:
        _arm_bare_basic(sv, lab)
        _feed(sv, [0x45, 0x3D, 0x31, 0x0D])         # "E=1" + RETURN (assignment)
        for _ in range(6):
            sv.run_for(0.3)
        assert (sv.read_byte(0xD020) & 0x0F) != 5, \
            "a non-EXIT 'E...' line wrongly triggered the swap-back"
