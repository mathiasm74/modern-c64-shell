"""Cross-bank calls on the EasyFlash cart, where the banking is REAL in VICE.

On the One ROM target VICE only sees far_call's shadow-exchange fallback
(test_far.py); here the callee is switched in with $DE00 and the caller
switched back the same way, which is the mechanism the cart runs. The editor
(ROMH bank 4) lists and saves a BASIC program through the util bank's
tokenizer (bank 2) -- two far calls -- and must still be itself afterwards.
"""

import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

_HERE = os.path.dirname(os.path.abspath(__file__))
_CRT = os.path.join(_HERE, "..", "build", "ef", "tardis.crt")
_STOCK_K = os.path.join(_HERE, "..", "stock-roms", "kernal.901227-03.bin")
_STOCK_B = os.path.join(_HERE, "..", "stock-roms", "basic.901226-01.bin")
_DISK = os.path.join(_HERE, "data", "test.d64")
_SCRATCH = os.path.join(_HERE, "data", "_scratch_ef_far.d64")
_HAVE = (os.path.exists(_CRT) and os.path.exists(_STOCK_K)
         and os.path.exists(_STOCK_B) and os.path.exists(_DISK))

if _HAVE:
    shutil.copyfile(_DISK, _SCRATCH)      # the save writes; never the fixture

FAR_DEPTH = 0x03A7


def _vice():
    sys.path.insert(0, os.path.join(_HERE, "lib"))
    from vice import Vice
    return Vice(kernal=_STOCK_K, basic=_STOCK_B, disk=_SCRATCH,
                extra_args=["-cartcrt", _CRT, "+easyflashjumper"])


def _boot(sv):
    for _ in range(60):
        sv.run_for(0.25)
        if "8: " in sv.screen_text() or "8>" in sv.screen_text():
            return
    raise AssertionError("no prompt:\n%s" % sv.screen_text())


def _type(sv, text):
    for chunk in [text[i:i + 9] for i in range(0, len(text), 9)]:
        sv.inject_keys(chunk)
        for _ in range(80):
            sv.run_for(0.1)
            if sv.read_byte(0xC6) == 0:
                break
    sv.run_for(1.0)


def _wait(sv, want, tries=12):
    for _ in range(tries):
        if want in sv.screen_text():
            return True
        sv.run_for(0.5)
    return want in sv.screen_text()


def test_ef_editor_lists_and_saves_basic_through_the_util_bank(v):
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt, stock ROMs or disk)")
        return
    with _vice() as sv:
        _boot(sv)
        _type(sv, "edit bas\r")
        assert _wait(sv, "10 PRINT"), \
            "no listing: the detokenize far call failed\n%s" % sv.screen_text()
        assert sv.read_byte(FAR_DEPTH) == 0, "FAR_DEPTH left set"

        _type(sv, "\x0f")                    # ^O: save -> tokenize far call
        assert _wait(sv, "wrote"), \
            "save failed: the tokenize far call\n%s" % sv.screen_text()
        _type(sv, "\x18")                    # ^X; saved, so it just exits
        assert _wait(sv, "8: "), "the editor did not exit\n%s" % sv.screen_text()

        # Open it again: what was saved is still a program that lists.
        _type(sv, "clear\r")
        _type(sv, "edit bas\r")
        assert _wait(sv, "30 REM DONE"), \
            "the saved program does not list back\n%s" % sv.screen_text()
        _type(sv, "\x18")
        assert _wait(sv, "8: ")
