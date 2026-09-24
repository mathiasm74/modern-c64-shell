"""Cross-bank calls: far_call (src/far.inc, src/rbcp/launch.s).

A running bank calls a SERVICE entry in another bank and gets back to itself.
The first user is the editor, whose BASIC tokenizer lives in the util bank.

On this target VICE has no One ROM, so far_call's fallback exchanges the
caller's image at $A000 with the callee's in the shadow RAM under the KERNAL
($E000, seeded by seed_far_bank). The real served path (LOAD_SLOT into slot 3,
SWITCH, SWITCH back) is hardware-only; the EasyFlash target runs real banking
in VICE (test_ef_far.py).
"""

import os
import re
import shutil

from lib.overlays import seed_edit, seed_far_bank, _seed_bank

_HERE = os.path.dirname(os.path.abspath(__file__))
_BUILD = os.path.join(_HERE, "..", "build")
_SRC = os.path.join(_HERE, "..", "src")
shutil.copy(os.path.join(_HERE, "data", "test.d64"),
            os.path.join(_HERE, "data", "_scratch_far.d64"))
VICE_DISK = "data/_scratch_far.d64"

FAR_DEPTH = 0x03A7
FAR_SVC = 0xFFA7
CR = 0x0D
CTRL_X = 0x18


def _keys(v, codes):
    codes = [c if isinstance(c, int) else ord(c) for c in codes]
    while codes:
        chunk, codes = codes[:8], codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        for _ in range(20):
            v.run_for(0.05)
            if v.read_byte(0x00C6) == 0:
                break


def _wait(v, needle, tries=40, chunk=0.15):
    for _ in range(tries):
        if needle in v.screen_text():
            return True
        v.run_for(chunk)
    return needle in v.screen_text()


def _ready(v):
    """The static checks above never run the CPU, so the first behaviour test
    may find the machine still booting; typed keys would be lost."""
    assert _wait(v, "8>", tries=80), "no prompt\n%s" % v.screen_text()


def _bank_img(bank):
    return open(os.path.join(_BUILD, "banks", bank + "_bank.bin"), "rb").read()


def _label(bank, name):
    path = os.path.join(_BUILD, "banks", bank + "_bank.labels")
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) >= 3 and p[2] == "." + name:
                return int(p[1], 16) & 0xFFFF
    raise AssertionError("%s not in %s" % (name, path))


def _entry_target(bank, n):
    img = _bank_img(bank)
    at = 4 + 3 * n
    assert img[at] == 0x4C, "%s entry %d is not a JMP" % (bank, n)
    return img[at + 1] | (img[at + 2] << 8)


# --- static checks ------------------------------------------------------------

def test_every_bank_shares_one_zero_page(v):
    """A service runs on its CALLER's C stack, which only works because every
    bank links the same cc65 zero page: 26 bytes at $40, with the stack pointer
    at $40 in all of them. A bank that grew a zero-page variable of its own
    would shift that layout, and a far call would push onto garbage."""
    (void) = v
    for bank in ("disk", "util", "files", "edit", "hex"):
        m = open(os.path.join(_BUILD, "banks", bank + "_bank.map")).read()
        seg = re.search(r"^ZEROPAGE\s+([0-9A-F]+)\s+([0-9A-F]+)", m, re.M)
        assert seg and (seg.group(1), seg.group(2)) == ("000040", "000059"), \
            "%s bank's zero page is not $40-$59: %r" % (
                bank, seg.groups() if seg else None)
        assert _label(bank, "c_sp") == 0x40, \
            "%s bank's C stack pointer is not at $40" % bank


def test_services_own_no_ram(v):
    """A service must not own BSS, DATA or zero page: that RAM is the caller's
    while the call lasts, and nothing re-initializes it for the service
    (bank_init is deliberately skipped). Read the util bank's module list."""
    (void) = v
    m = open(os.path.join(_BUILD, "banks", "util_bank.map")).read()
    block = re.search(r"^ub_basic_tok\.o:\n((?:\s{4}\S.*\n)+)", m, re.M)
    assert block, "ub_basic_tok.o is not in the util bank's map"
    segs = set(re.findall(r"^\s+(\w+)\s+Offs=", block.group(1), re.M))
    assert segs <= {"CODE", "RODATA"}, \
        "the BASIC services own RAM segments: %s" % sorted(segs)


def test_far_entries_match_the_util_table(v):
    """The target numbers are written in three places -- the util bank's JMP
    order, basic_tok.h and the edit bank's stubs -- and nothing links them.
    A service entry must also NOT go through bank_init, or it would wipe the
    calling bank's RAM: its JMP must land on the function itself."""
    (void) = v
    hdr = open(os.path.join(_SRC, "banks", "basic_tok.h")).read()
    stubs = open(os.path.join(_SRC, "banks", "far_util.s")).read()
    for name, fn in (("DETOKENIZE", "_basic_detokenize"),
                     ("TOKENIZE", "_basic_tokenize")):
        h = int(re.search(r"#define UTIL_%s\s+(\d+)" % name, hdr).group(1))
        s = int(re.search(r"UTIL_%s\s*=\s*(\d+)" % name, stubs).group(1))
        assert h == s, "basic_tok.h says %s is entry %d, far_util.s %d" % (name, h, s)
        assert _entry_target("util", h) == _label("util", fn), \
            "util entry %d is not %s (or goes through bank_init)" % (h, fn)
    assert int(re.search(r"BANK_UTIL\s*=\s*(\d+)", stubs).group(1)) == \
        int(re.search(r"#define BANK_UTIL\s+(\d+)",
                      open(os.path.join(_SRC, "shell.h")).read()).group(1)), \
        "far_util.s and shell.h disagree on the util bank's id"


def test_far_svc_is_svc_13(v):
    """The banks bind far_svc to $FFA7; the SVC table must have far_call there."""
    (void) = v
    kernal = open(os.path.join(_BUILD, "kernal.bin"), "rb").read()
    at = FAR_SVC - 0xE000
    assert kernal[at] == 0x4C, "no JMP at $FFA7"
    target = kernal[at + 1] | (kernal[at + 2] << 8)
    labels = {}
    for line in open(os.path.join(_BUILD, "labels.txt")):
        p = line.split()
        if len(p) >= 3 and p[0] == "al":
            labels[p[2].lstrip(".")] = int(p[1], 16) & 0xFFFF
    assert target == labels["far_call"], "$FFA7 does not jump to far_call"


# --- behaviour ----------------------------------------------------------------

def test_basic_listing_goes_through_the_util_bank(v):
    """The editor lists a BASIC program with the util bank's detokenizer, gets
    back to its own image afterwards (it keeps running and exits cleanly), and
    the depth flag is clear again."""
    _ready(v)
    seed_edit(v)
    _keys(v, "edit bas")
    _keys(v, [CR])
    assert _wait(v, "10 PRINT"), "no listing\n%s" % v.screen_text()
    assert v.read_byte(FAR_DEPTH) == 0, "FAR_DEPTH left set after the call"
    _keys(v, [CTRL_X])
    assert _wait(v, "8>"), "the editor did not come back\n%s" % v.screen_text()


def test_missing_callee_is_reported_and_the_caller_survives(v):
    """With no util bank in the shadow the far call fails cleanly: $FFFF, the
    editor's own image put back at $A000, and a message instead of a listing.
    The document stays empty and nameless, so a save cannot write over the
    program."""
    _ready(v)
    _seed_bank(v, "edit_bank.bin")
    v.write_memory(0xE000, [0, 0, 0, 0])        # no "bnk" in the shadow
    _keys(v, "edit bas")
    _keys(v, [CR])
    assert _wait(v, "no basic support"), \
        "a failed far call was not reported\n%s" % v.screen_text()
    assert "10 PRINT" not in v.screen_text()
    assert v.read_byte(FAR_DEPTH) == 0, "FAR_DEPTH left set after a failed call"
    _keys(v, [CTRL_X])
    # Surviving IS the check that the exchange put the editor back: it ran on
    # after the failed call and exited through its own code at $A000. (The
    # shadow itself cannot be read back here -- the monitor sees $E000 as the
    # CPU does, which is the KERNAL ROM.)
    assert _wait(v, "8>"), "the editor did not survive\n%s" % v.screen_text()


def test_zz_a_far_call_inside_a_far_call_is_refused(v):
    """One level only: a second far call would load over the first callee while
    it runs. Called with FAR_DEPTH already set, far_call must return $FFFF at
    once and leave the flag alone. (Parks the CPU; the runner sorts tests by name, hence zz.)"""
    seed_far_bank(v, "util_bank.bin")
    stub = [
        0xA9, 0x01, 0x8D, 0xA7, 0x03,           # lda #1 / sta FAR_DEPTH
        0xA0, 0x26,                             # ldy #(1<<5)|6
        0xA9, 0x00, 0xA2, 0x10,                 # lda #0 / ldx #$10
        0x20, 0xA7, 0xFF,                       # jsr far_svc
        0x8D, 0x00, 0x0A, 0x8E, 0x01, 0x0A,     # sta $0A00 / stx $0A01
        0x4C, 0x14, 0x09,                       # jmp * (park)
    ]
    v.write_memory(0x0900, stub)
    v.write_memory(0x0A00, [0, 0])
    v.run_at(0x0900, 0.3)
    assert v.read_memory(0x0A00, 2) == [0xFF, 0xFF], \
        "a nested far call was not refused: %r" % v.read_memory(0x0A00, 2)
    assert v.read_byte(FAR_DEPTH) == 1, "the refusal touched FAR_DEPTH"
