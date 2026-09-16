"""Tardis itself, built for EasyFlash (PLAN.md section 7, phase 2).

The shell, the parser and every command are the SAME sources as the One ROM
build -- only the platform layer (src/ef/platform.s) and the linker config
differ. This checks the port boots on a STOCK machine with the cart attached,
draws its banner, and runs commands.

What is NOT expected to work yet: bank commands. The bank images are still
linked against the One ROM's SVC address ($FF80, which here belongs to the stock
KERNAL), so the cart carries $FF filler in banks 1..5 -- and bank_call is
expected to report that rather than run it. Phase 3 relinks them.
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

_HERE = os.path.dirname(os.path.abspath(__file__))
_CRT = os.path.join(_HERE, "..", "build", "ef", "tardis.crt")
_STOCK_K = os.path.join(_HERE, "..", "stock-roms", "kernal.901227-03.bin")
_STOCK_B = os.path.join(_HERE, "..", "stock-roms", "basic.901226-01.bin")
_HAVE = (os.path.exists(_CRT) and os.path.exists(_STOCK_K)
         and os.path.exists(_STOCK_B))


def _vice():
    sys.path.insert(0, os.path.join(_HERE, "lib"))
    from vice import Vice
    return Vice(kernal=_STOCK_K, basic=_STOCK_B,
                extra_args=["-cartcrt", _CRT, "+easyflashjumper"])


def _boot(sv):
    """Run until the shell's prompt appears; return the screen."""
    got = ""
    for _ in range(40):
        sv.run_for(0.25)
        got = sv.screen_text()
        if "8>" in got:
            return got
    raise AssertionError("the EF build never reached its prompt:\n%s" % got)


def _type(sv, text):
    """Type a line, ten characters at a time (the keyboard buffer's depth)."""
    for chunk in [text[i:i + 9] for i in range(0, len(text), 9)]:
        sv.inject_keys(chunk)
        for _ in range(40):
            sv.run_for(0.1)
            if sv.read_byte(0xC6) == 0:
                break
    sv.run_for(0.8)


def test_ef_build_boots_to_the_tardis_prompt(v):
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt or no stock ROMs)")
        return
    with _vice() as sv:
        got = _boot(sv)
        # The banner proves main()'s environment is real, not just that some
        # code ran: it is printed through CHROUT, which means CINT ran, our
        # chrout_impl is on $0326, and the stock $FFD2 routes through it.
        assert "Tardis DOS" in got, "banner missing:\n%s" % got
        assert "power shell" in got, "banner incomplete:\n%s" % got
        assert "Free ROM bytes" in got, "free-bytes line missing:\n%s" % got


def test_ef_build_runs_a_resident_command(v):
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt or no stock ROMs)")
        return
    with _vice() as sv:
        _boot(sv)
        # `ver` is resident, so this exercises the whole loop -- our keyboard
        # scan on $0314 (which must leave through $EA81, not RTI: the stock
        # $FF48 already pushed the registers), readline, dispatch, chrout.
        _type(sv, "ver\r")
        got = sv.screen_text()
        assert "Tardis DOS v" in got, "ver produced nothing:\n%s" % got


def test_ef_bank_command_reports_unavailable_rather_than_crashing(v):
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt or no stock ROMs)")
        return
    with _vice() as sv:
        _boot(sv)
        _type(sv, "help\r")
        got = sv.screen_text()
        # Banks 1..5 are $FF filler until phase 3. bank_call's "bnk" magic check
        # must reject that -- and, crucially, the shell must survive: the switch
        # pulls ROML out from under bank_call unless every bank repeats it.
        assert "unavailable" in got, \
            "a missing bank should be reported, not run:\n%s" % got
        _type(sv, "ver\r")
        assert "Tardis DOS v" in got or "Tardis DOS v" in sv.screen_text(), \
            "the shell did not survive a failed bank call:\n%s" % sv.screen_text()


def test_every_crt_bank_carries_an_identical_roml(v):
    """$DE00 banks BOTH windows, so ROML is only "always mapped" if it repeats.

    bank_call runs from ROML and writes $DE00 mid-routine; if the incoming bank
    held a different ROML, the CPU's next fetch would come from a different
    image at the same address. This is the invariant that makes it safe.
    """
    (void) = v
    if not os.path.exists(_CRT):
        print("      (skipped: no tardis.crt)")
        return
    data = open(_CRT, "rb").read()
    hdr = struct.unpack(">I", data[0x10:0x14])[0]
    off, roml = hdr, {}
    while off < len(data):
        assert data[off:off + 4] == b"CHIP", "bad chip packet at $%X" % off
        plen, bank, load = (struct.unpack(">I", data[off + 4:off + 8])[0],
                            struct.unpack(">H", data[off + 10:off + 12])[0],
                            struct.unpack(">H", data[off + 12:off + 14])[0])
        size = struct.unpack(">H", data[off + 14:off + 16])[0]
        if load == 0x8000:
            roml[bank] = data[off + 16:off + 16 + size]
        off += plen
    assert len(roml) >= 2, "expected several banks, got %d" % len(roml)
    first = roml[0]
    for bank, image in sorted(roml.items()):
        assert image == first, \
            "bank %d's ROML differs from bank 0's -- bank_call would be " \
            "switched out from under itself" % bank
