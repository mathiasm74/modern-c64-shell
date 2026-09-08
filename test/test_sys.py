"""sys <addr> -- call machine code in the current (Tardis) environment.

`sys` JSRs into ML at the given address (decimal by default, hex with `$`) and
returns to the prompt when the routine RTSes -- BASIC's SYS, but running under
Tardis rather than swapping to stock ROMs (that's `run`). The classic use is
tripping an I/O-region device, e.g. a SIDKick pico's `sys 54301`.

We test it the way that ML would behave: poke a tiny routine into user RAM that
writes a recognizable value to an I/O register and RTSes, `sys` to it, and check
both that the write happened (the routine ran) and that the shell came back
(a follow-up command still dispatches).
"""

CR = 0x0D

# LDA #$07 / STA $D020 / RTS -- set the border to 7 (yellow), then return.
_ROUTINE = [0xA9, 0x07, 0x8D, 0x20, 0xD0, 0x60]
_ADDR = 0x2000          # free user RAM (clear of screen and the shell's $C000+)


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [CR])
    v.write_byte(0x00C6, len(text) + 1)


def _border(v):
    return v.read_byte(0xD020) & 0x0F


def test_sys_decimal_calls_ml_and_returns(v):
    v.run_for(0.3)
    v.write_byte(0xD020, 0x00)              # clear border so 7 is unambiguous
    v.write_memory(_ADDR, _ROUTINE)
    _type(v, "sys 8192")                    # $2000 = 8192, decimal like SIDKick's
    for _ in range(10):
        v.run_for(0.3)
        if _border(v) == 7:
            break
    assert _border(v) == 7, \
        "sys did not call the ML routine (border still $%02X)" % _border(v)

    # The routine RTSed, so the shell must be back and dispatching: `ver` prints.
    _type(v, "ver")
    for _ in range(10):
        v.run_for(0.3)
        if "Tardis DOS v" in v.screen_text():
            return
    assert False, "shell did not return to the prompt after sys\n%s" % v.screen_text()


def test_sys_hex_addr(v):
    v.run_for(0.3)
    v.write_byte(0xD020, 0x00)
    v.write_memory(_ADDR, _ROUTINE)
    _type(v, "sys $2000")                   # hex form
    for _ in range(10):
        v.run_for(0.3)
        if _border(v) == 7:
            return
    assert False, "sys with a $hex address did not call the routine"


def test_sys_no_arg_reports_usage(v):
    v.run_for(0.3)
    _type(v, "sys")
    for _ in range(8):
        v.run_for(0.3)
        if "usage: sys" in v.screen_text():
            return
    assert False, "bare sys did not print a usage message\n%s" % v.screen_text()
