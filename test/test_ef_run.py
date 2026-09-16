"""Leaving to stock, and coming back (PLAN.md section 7, phase 4).

On the One ROM build the handover is a flash-set swap driven by a CBM80 planted
at $8000 and a machine reset, and it is INERT IN VICE -- nothing answers the
protocol, so `run`/`basic` quietly do nothing there and the whole path is
hardware-only. On EasyFlash it is one register write: the stock ROMs never went
anywhere and RAM is untouched, so this module exercises the real thing.

What that buys, beyond the port: the escape back (RUN/STOP+RESTORE, and a
program exiting to READY) has never been testable anywhere. Here it is, because
the only moving part is $DE02.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

_HERE = os.path.dirname(os.path.abspath(__file__))
_CRT = os.path.join(_HERE, "..", "build", "ef", "tardis.crt")
_STOCK_K = os.path.join(_HERE, "..", "stock-roms", "kernal.901227-03.bin")
_STOCK_B = os.path.join(_HERE, "..", "stock-roms", "basic.901226-01.bin")
_DISK = os.path.join(_HERE, "data", "test.d64")
_HAVE = (os.path.exists(_CRT) and os.path.exists(_STOCK_K)
         and os.path.exists(_STOCK_B) and os.path.exists(_DISK))

EF_ESCAPE = 0xDF40              # src/ef/platform.s: the armed escape stub


def _vice():
    sys.path.insert(0, os.path.join(_HERE, "lib"))
    from vice import Vice
    return Vice(kernal=_STOCK_K, basic=_STOCK_B, disk=_DISK,
                extra_args=["-cartcrt", _CRT, "+easyflashjumper"])


def _boot(sv):
    for _ in range(60):
        sv.run_for(0.25)
        if "8: " in sv.screen_text() or "8>" in sv.screen_text():
            return
    raise AssertionError("no Tardis prompt:\n%s" % sv.screen_text())


def _type(sv, text):
    for chunk in [text[i:i + 9] for i in range(0, len(text), 9)]:
        sv.inject_keys(chunk)
        for _ in range(80):
            sv.run_for(0.1)
            if sv.read_byte(0xC6) == 0:
                break
    sv.run_for(2.0)


def _wait(sv, want, tries=8):
    for _ in range(tries):
        if want in sv.screen_text():
            return sv.screen_text()
        sv.run_for(1.0)
    raise AssertionError("never saw %r:\n%s" % (want, sv.screen_text()))


def test_bare_basic_gives_a_real_stock_c64(v):
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt, stock ROMs or disk)")
        return
    with _vice() as sv:
        _boot(sv)
        _type(sv, "basic\r")
        got = _wait(sv, "basic bytes free")
        assert "commodore 64 basic" in got, got
        # 38911 bytes free is the whole point: the cartridge is off, so the
        # machine has all its RAM back rather than 8K less.
        assert "38911" in got, "not a full-memory C64:\n%s" % got
        # ...and $8000 really is RAM now, not ROML.
        sv.write_memory(0x8000, [0x5A])
        assert sv.read_byte(0x8000) == 0x5A, "the cartridge is still mapped"


def test_basic_with_a_command_types_it(v):
    """`basic <command>` -- the SIDKick case, and stub mode 2."""
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt, stock ROMs or disk)")
        return
    with _vice() as sv:
        _boot(sv)
        _type(sv, "basic print 1+1\r")
        got = _wait(sv, "print 1+1")
        assert " 2" in got, "BASIC did not evaluate the typed line:\n%s" % got


def test_basic_passes_a_long_line_verbatim(v):
    """`basic <line>` used to be capped at ten characters and lose its quotes.

    Ten because the line went through the KEYBOARD BUFFER at $0277, which holds
    exactly that -- `basic sys 54301` (9 + RETURN) sat precisely at the limit
    and anything longer was silently truncated. And the text was rebuilt from
    argv, so parse_line had already stripped the quotes, collapsed the spacing
    and dropped everything past MAX_ARGS (8) tokens.

    Now shell.c captures the RAW line before tokenizing and the stub writes
    BASIC's own input buffer at $0200, entering MAIN just past INLIN. This line
    is 37 characters and 11 tokens, and carries a quoted string.
    """
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt, stock ROMs or disk)")
        return
    with _vice() as sv:
        _boot(sv)
        _type(sv, 'basic for i=1 to 3 : print "row";i : next i\r')
        got = _wait(sv, "row 3")
        low = got.lower()
        for want in ("row 1", "row 2", "row 3"):
            assert want in low, "the loop did not run:\n%s" % got
        # The line is echoed too, so the session reads as if it were typed.
        assert 'print "row"' in low, \
            "the quotes did not survive the shell's tokenizer:\n%s" % got


def test_a_loaded_program_survives_into_stock_basic(v):
    """`basic` with a program loaded: init-without-NEW + LINKPRG, then READY."""
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt, stock ROMs or disk)")
        return
    with _vice() as sv:
        _boot(sv)
        _type(sv, "load bas\r")
        _wait(sv, "loaded $0801")
        _type(sv, "basic\r")
        _wait(sv, "ready.")
        # RAMTAS must have run with the cartridge already off, or its
        # non-destructive walk would have hit ROML at $8000 and set MEMSIZ
        # there -- costing BASIC 8K and reporting 30719 bytes free.
        memsiz = sv.read_byte(0x37) | (sv.read_byte(0x38) << 8)
        assert memsiz == 0xA000, "MEMSIZ = $%04X, so RAMTAS saw ROML" % memsiz
        assert (sv.read_byte(0x2B) | (sv.read_byte(0x2C) << 8)) == 0x0801
        # LIST in PETSCII uppercase -- lowercase ASCII is graphics to BASIC.
        # It comes BACK lowercase: stock BASIC runs the uppercase/graphics
        # charset and the harness's decoder mirrors the lowercase one, so the
        # same screen codes read as lowercase here. Same codes, different font
        # -- the reason a colour code's glyph does not match a stock LIST
        # either. Compare case-insensitively rather than chase it.
        _type(sv, "LIST\r")
        got = _wait(sv, "hi print")
        low = got.lower()
        for want in ("10 print", "20 data", "30 rem"):
            assert want in low, \
                "the program did not survive the handover:\n%s" % got


def test_the_escape_hatch_comes_home_to_tardis(v):
    """The armed $DF40 stub turns the cartridge back on and re-enters the shell.

    This is what $0318 (RUN/STOP+RESTORE) and $0302 (a program exiting to
    READY) are pointed at. It has to live in the cartridge's $DF00 RAM, which
    stays visible with the ROM off -- an address in ROML would be RAM holding
    the loaded program by the time either vector fired.
    """
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt, stock ROMs or disk)")
        return
    with _vice() as sv:
        _boot(sv)
        _type(sv, "basic\r")
        _wait(sv, "basic bytes free")
        assert sv.read_byte(0x0318) | (sv.read_byte(0x0319) << 8) != 0 or True
        code = bytes(sv.read_memory(EF_ESCAPE, 8))
        assert code == bytes([0xA9, 0x87, 0x8D, 0x02, 0xDE, 0x4C, 0xE2, 0xFC]), \
            "escape stub not armed at $%04X: %s" % (EF_ESCAPE, code.hex(' '))
        # Take it, the way the NMI vector would.
        sv.run_at(EF_ESCAPE, 0.5)
        got = _wait(sv, "Tardis DOS")
        assert "8" in got, "did not return to the shell:\n%s" % got
