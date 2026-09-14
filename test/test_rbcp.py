"""RBCP bank-swap launcher layout and copy/patch behavior.

The actual ROM swap can only be tested on real hardware -- VICE has no One
ROM model, so writes to the command page are inert. What we *can* verify in
VICE is the part of the launcher that runs on the C64 before the swap:
that the RBCP library is laid out where we said it is (KERNAL ROM, runs at
$C800 in RAM), that _rbcp_launch_stock copies the right number of bytes
from the right source to the right destination, and that it patches the
trampoline's "JMP $0000" with the entry address the caller passed.

If a future hardware test shows the swap itself misbehaves, that's a
separate diagnosis -- the protocol part is in the vendored library.
"""

import os
import re

_BUILD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build")
_LABELS = os.path.join(_BUILD, "labels.txt")


def _labels():
    out = {}
    with open(_LABELS) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 3 and parts[0] == "al":
                out[parts[2].lstrip(".")] = int(parts[1], 16) & 0xFFFF
    return out


def test_rbcp_segment_layout(v):
    # The vendored library is stored in KERNAL ROM (load) and linked to run
    # from RAM at $C800. Both addresses are exposed by ld65's segment
    # symbols and the launcher relies on them being where we expect.
    L = _labels()
    load = L["__RBCP_CODE_LOAD__"]
    run = L["__RBCP_CODE_RUN__"]
    size = L["__RBCP_CODE_SIZE__"]
    assert 0xE000 <= load <= 0xFFFF, \
        "RBCP_CODE load addr $%04X not in KERNAL ROM" % load
    assert run == 0xC800, \
        "RBCP_CODE run addr $%04X not at $C800 (RBCP_RAM start)" % run
    assert 0x0100 < size < 0x0600, \
        "RBCP_CODE size $%X looks wrong (expect roughly 0x200-0x300)" % size
    # The trampoline lives inside RBCP_CODE so it ends up in RAM too.
    tramp = L["rbcp_trampoline"]
    assert run <= tramp < run + size, "rbcp_trampoline $%04X outside RBCP_RAM" % tramp


def test_launch_copies_library_to_ram(v):
    # _rbcp_launch_stock copies the whole RBCP_CODE block (library + the
    # in-RAM trampoline) from its KERNAL ROM home to its run-address in
    # RBCP_RAM, then JMPs into the trampoline. The trampoline's job from
    # there is RBCP-side -- protocol calls then a JMP through (FFFC) -- and
    # in VICE without a One ROM model the protocol calls time out and
    # control falls through. What we can verify in VICE is that the copy
    # happened correctly.
    L = _labels()
    launch = L["_rbcp_launch_stock"]
    load = L["__RBCP_CODE_LOAD__"]
    run = L["__RBCP_CODE_RUN__"]

    # Stub at $1000: JSR launch; spin if it ever returns (it doesn't).
    stub = [0x20, launch & 0xFF, (launch >> 8) & 0xFF,
            0x4C, 0x03, 0x10]      # JMP $1003 (the JMP itself)
    v.write_memory(0x1000, stub)
    v.run_at(0x1000, 0.5)

    # After the launch runs, the trampoline's JMP (FFFC) re-enters our shell
    # (since stock KERNAL isn't actually mapped in VICE). Garbage execution
    # along the way may have touched $01 and unmapped the KERNAL view;
    # restore the standard mapping before reading ROM.
    v.write_byte(0x01, 0x37)

    # The library's first byte (LDA opcode $AD for the first export
    # rbcp_knock) should now match between ROM source and RAM destination.
    rom_first = v.read_byte(load)
    ram_first = v.read_byte(run)
    assert rom_first == ram_first, \
        "library first byte mismatch: ROM=$%02X RAM=$%02X" % (rom_first, ram_first)
    # rbcp_knock opens with `jsr rbcp_vic_guard` (the badline guard) since
    # v0.1.56; before that it began with its first RBCP_READ (LDA absolute).
    assert rom_first == 0x20, "expected library to start with JSR ($20)"


def test_escape_invalidates_planted_cbm80(v):
    # The RUN/STOP+RESTORE escape (rbcp_escape_tramp) reboots into the shell.
    # `run` planted a CBM80 autostart signature at $8004-$8008 so the stock
    # reset would launch the program; the shell's reset runs the SAME check, so
    # the escape must invalidate it first or the shell would just relaunch the
    # program we're escaping from. Copy the RBCP library into its RAM run
    # location (the swap does this before the escape ever runs), plant the
    # signature byte, run the escape trampoline, and confirm it's cleared. The
    # RBCP calls after the clear are inert in VICE, but the clear is the first
    # thing the trampoline does, so it always lands.
    L = _labels()
    load = L["__RBCP_CODE_LOAD__"]
    run = L["__RBCP_CODE_RUN__"]
    size = L["__RBCP_CODE_SIZE__"]
    esc = L["rbcp_escape_tramp"]

    v.write_memory(run, list(v.read_memory(load, size)))   # ROM -> RAM run addr
    v.write_byte(0x8004, 0xC3)                             # plant CBM80 sig byte
    v.run_at(esc, 0.3)
    assert v.read_byte(0x8004) != 0xC3, \
        "escape did not invalidate the planted CBM80 signature ($8004 still $C3)"


def test_bank_command_fails_gracefully_without_device(v):
    """A command whose code lives outside the 16KB ROM must report, not jump.

    `about` is the case that used to exercise the RAM-overlay fetch: its code
    was in a flash set and the resident thunk pulled it in over RBCP. It is in
    the util bank now -- the last overlay retired -- so the failure it reports
    with no device answering is the bank one, and the point of the test is
    unchanged: no device, no jump into whatever happens to be at $A000.
    """
    v.run_for(0.3)
    v.write_memory(0x0277, [ord(c) for c in "about"] + [0x0D])
    v.write_byte(0x00C6, 6)
    for _ in range(10):
        v.run_for(0.5)
        if "unavailable" in v.screen_text():
            break
    assert "bank unavailable" in v.screen_text(), \
        "about did not report the bank as unavailable\n%s" % v.screen_text()


def test_back_channel_window_is_free_fill(v):
    # The RBCP back-channel ($FE00-$FF0F, CONFIG_RBCP_BCH_BASE/_SIZE in
    # rbcp_config.s) is ROM the One ROM device OVERWRITES in the served
    # image during every command-response session. Any real content there
    # gets corrupted on hardware -- persistently, until a reflash. That
    # shipped once (v0.12: code grew past the old $FA00 window and every
    # overlay fetch sprayed bytes over live shell code), so this asserts
    # the built image keeps the window as pure $FF fill.
    with open(_LABELS.replace("labels.txt", "kernal.bin"), "rb") as f:
        rom = f.read()
    base = 0xFE00 - 0xE000
    window = rom[base:base + 272]
    bad = [i for i, b in enumerate(window) if b != 0xFF]
    assert not bad, \
        "back-channel window has %d non-$FF bytes (first at $%04X) -- " \
        "code/data grew into device-writable ROM" % (len(bad), 0xFE00 + bad[0])


# --- the bank RAM ceiling and the loader guards that enforce it -------------
# A bank's DATA/BSS/C stack are carved out of the program load area, and
# `load`/`fload` run FROM a bank -- so a program growing into that window
# overwrites the loader underneath itself, mid-transfer. Two guards stop it:
# the C `load` compares per byte (BANK_RAM_FLOOR), and the Epyx receiver tests
# the destination's high byte when it crosses a page (BANKPG), which is free on
# 255 of every 256 bytes but only EXACT if the window is page-aligned.
#
# The realistic way this rots is someone moving the bank's RAM and not moving
# the guards, so check all three agree. No VICE needed.

_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def _read(*parts):
    with open(os.path.join(_ROOT, *parts)) as f:
        return f.read()


def _bank_ram_start(cfg):
    m = re.search(r"DATARUN:\s*file\s*=\s*\"\",\s*start\s*=\s*\$([0-9A-Fa-f]{4})",
                  _read("cfg", cfg))
    assert m, "no DATARUN line in cfg/%s" % cfg
    return int(m.group(1), 16)


def test_bank_ram_ceiling_and_loader_guards_agree(v):
    (void) = v                          # static check; no machine needed

    disk = _bank_ram_start("disk_bank.cfg")
    files = _bank_ram_start("files_bank.cfg")
    assert disk == files, \
        "banks must SHARE one RAM window (only one is served at a time): " \
        "disk $%04X vs files $%04X" % (disk, files)

    assert disk & 0xFF == 0, \
        "the bank RAM window must be PAGE-ALIGNED ($%04X): the Epyx receiver's " \
        "guard tests only the destination's high byte" % disk

    # There are TWO guard pages now: the receiver is built for the bank AND, via
    # KLOAD_BUILD, for the patch that runs inside the stock KERNAL, where there
    # is no bank to protect and the thing to stay out of is the I/O window.
    # Match them separately -- a plain search finds whichever comes first in the
    # conditional and silently checks the wrong one against the wrong ceiling.
    src = _read("src", "fastload_recv.s")
    kl = re.search(r"\.ifdef KLOAD_BUILD\s*\nBANKPG\s*=\s*\$([0-9A-Fa-f]{2})", src)
    bank = re.search(r"\.else\s*\nBANKPG\s*=\s*\$([0-9A-Fa-f]{2})", src)
    assert kl and bank, "the two BANKPG definitions are not both in fastload_recv.s"
    assert int(bank.group(1), 16) == disk >> 8, \
        "Epyx receiver guard page $%02X != bank RAM page $%02X -- a fast load " \
        "would overrun the bank's own stack" % (int(bank.group(1), 16), disk >> 8)
    assert int(kl.group(1), 16) == 0xD0, \
        "the stock-KERNAL patch's guard is $%02X, not $D0 -- a load there must " \
        "stop below the I/O window, not at a bank window that does not exist" \
        % int(kl.group(1), 16)

    m = re.search(r"#define BANK_RAM_FLOOR\s+0x([0-9A-Fa-f]{4})",
                  _read("src", "banks", "disk_bank.c"))
    assert m, "BANK_RAM_FLOOR missing from src/banks/disk_bank.c"
    assert int(m.group(1), 16) == disk, \
        "`load` floor $%04X != bank RAM start $%04X" % (int(m.group(1), 16), disk)


# --- firmware chip-set shapes ----------------------------------------------
# A BANK set must be [kernal | charset | bank image]. The KERNAL and charset
# have to be byte-identical to the base set, because SWITCH_SLOT swaps under a
# running CPU: only the $A000 half may differ.
#
# This exists because that invariant was broken by hand and reached hardware.
# The edit bank's set was created by editing the OVERLAY set it replaced --
# and an overlay set is the same image on all three chips. The result served
# the editor's code as the character ROM (the screen filled with giant garbage
# glyphs) and as the KERNAL. Nothing in the build or the suite noticed: the
# images were all valid, just wired to the wrong chips.

import json


def _chip_sets():
    with open(os.path.join(_ROOT, "cfg", "onerom-stock.json")) as f:
        return json.load(f)["chip_sets"]


def test_bank_flash_sets_have_the_right_chip_layout(v):
    (void) = v                          # static check; no machine needed

    sets = _chip_sets()
    banks = [(i, s) for i, s in enumerate(sets)
             if any("banks/" in c.get("file", "") for c in s["chips"])]
    assert banks, "no bank sets found in cfg/onerom-stock.json"

    for i, s in banks:
        files = [c.get("file", "") for c in s["chips"]]
        assert len(files) == 3, "slot %d: a bank set needs 3 chips, got %d" % (i, len(files))
        assert files[0].endswith("kernal.bin"), \
            "slot %d chip 0 must be the KERNAL (byte-identical to the base so " \
            "the live swap is safe), got %r" % (i, files[0])
        assert "characters" in files[1], \
            "slot %d chip 1 must be the character ROM -- anything else is served " \
            "to the VIC as the charset, got %r" % (i, files[1])
        assert "banks/" in files[2], \
            "slot %d chip 2 must be the bank image, got %r" % (i, files[2])
        assert files[0] != files[2], \
            "slot %d serves the same image as KERNAL and bank -- this is the " \
            "overlay-set shape (one image on all chips), not a bank set" % i


def test_bank_entry_indices_match_the_entry_tables(v):
    """The entry NUMBER a caller uses must reach the function it names.

    An entry index is encoded in two unrelated places: the order of the JMPs in
    the bank's crt0 ENTRY table, and the literal in shell.c's dispatch row (or in
    fs.c, for the boot-time identify). Nothing ties them together, so removing an
    entry silently shifts every later one -- which is exactly what happened when
    border/bg/text left the files bank for the util bank and everything after
    them renumbered.

    Most of those commands have tests that would notice. `identify` does not: it
    runs once at boot, prints nothing by design and swallows a failed bank call,
    so a wrong index there is invisible. Check the table directly instead: follow
    entry N's JMP in the built image and require it to land on the intended
    function (via the bank's own label file, or its bank_init trampoline).
    """
    (void) = v

    def entry_target(bank, n):
        img = open(os.path.join(_BUILD, "banks", bank + "_bank.bin"), "rb").read()
        at = 4 + 3 * n                      # $A000 "bnk" + id, then the JMPs
        assert img[at] == 0x4C, \
            "%s entry %d is not a JMP (got $%02X)" % (bank, n, img[at])
        return img[at + 1] | (img[at + 2] << 8)

    def label(bank, name):
        path = os.path.join(_BUILD, "banks", bank + "_bank.labels")
        with open(path) as f:
            for line in f:
                p = line.split()
                if len(p) >= 3 and p[2] == "." + name:
                    return int(p[1], 16) & 0xFFFF
        raise AssertionError("%s not in %s" % (name, path))

    # Each entry goes through a bank_init trampoline, so follow that one hop: the
    # trampoline is `jsr bank_init / jmp _target`, and the jmp is at +3.
    def through_init(bank, n):
        img = open(os.path.join(_BUILD, "banks", bank + "_bank.bin"), "rb").read()
        tramp = entry_target(bank, n) - 0xA000
        assert img[tramp] == 0x20, "entry %d of %s does not jsr bank_init" % (n, bank)
        assert img[tramp + 3] == 0x4C, "no jmp after bank_init in %s entry %d" % (bank, n)
        return img[tramp + 4] | (img[tramp + 5] << 8)

    # identify_boot_device's index is READ FROM fs.c, not assumed. Checking the
    # image against itself would be circular: it would confirm that entry 12 is
    # identify while the caller happily asked for 15. The literal in the source is
    # the half that rots, so that is the half to read.
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "src", "commands", "fs.c")).read()
    m = re.search(r"bank_try\(\(BANK_FILES\s*<<\s*5\)\s*\|\s*(\d+)", src)
    assert m, "identify_boot_device's bank_try call is gone or reshaped"
    n = int(m.group(1))
    assert through_init("files", n) == label("files", "_fb_identify"), \
        "fs.c asks for files entry %d, which is not _fb_identify -- it and the " \
        "ENTRY table in crt0_files_bank.s have drifted apart" % n

    # shell.c routes border/bg/text to util entries 3/4/5.
    for n, name in ((3, "_ub_border"), (4, "_ub_bg"), (5, "_ub_text")):
        assert through_init("util", n) == label("util", name), \
            "util entry %d does not reach %s" % (n, name)


def test_kload_is_linked_for_the_stock_kernals_tape_space(v):
    """The LOAD patch must be built to run where the tape code is, and must fit.

    None of it can be exercised in VICE -- the swap and every RBCP command are
    inert without a One ROM -- but the arithmetic can be pinned, and it is the
    part that rots silently: the link address, the size against the space that is
    actually free, and the ILOAD vector-table entry it repoints. Get any of them
    wrong and the patch lands somewhere plausible and the machine dies later,
    under stock ROMs, with nothing on screen to say why.

    docs/TAPE-SPACE.md establishes $F8E2-$FB8D as reachable only from the tape
    paths; tools/kernal_map.py regenerates that.
    """
    (void) = v

    kl = os.path.join(_BUILD, "kload.labels")
    assert os.path.exists(kl), "build/kload.labels missing -- the patch did not link"
    syms = {}
    with open(kl) as f:
        for line in f:
            p = line.split()
            if len(p) >= 3 and p[0] == "al":
                syms[p[2].lstrip(".")] = int(p[1], 16) & 0xFFFF

    assert syms.get("kload_entry") == 0xF8E2, \
        "the patch entry is at $%04X, not $F8E2 -- cfg/kload.cfg and " \
        "docs/TAPE-SPACE.md disagree" % (syms.get("kload_entry") or 0)

    # Two pieces, because the tape space is two runs with LIVE stock code between
    # them ($FB8E-$FBA5). Each must stay inside its own run: overflow here is not
    # a link error, it is the stock KERNAL quietly losing a routine.
    for name, start, last in (("kload.bin", 0xF8E2, 0xFB8D),
                              ("kload2.bin", 0xFBA6, 0xFC92)):
        size = os.path.getsize(os.path.join(_BUILD, name))
        assert start + size - 1 <= last, \
            "%s is %d bytes and would run to $%04X, past its tape-only region " \
            "at $%04X -- it would overwrite live stock code" \
            % (name, size, start + size - 1, last)

    # The entry must actually reach the fast path, not just fall through to the
    # stock loader: a wedge that only ever jumps to $F4B8 is the stage-1 stub and
    # would look identical from outside, minus the speed.
    body = open(os.path.join(_BUILD, "kload.bin"), "rb").read()
    fast = syms.get("kl_fast")
    assert fast, "kl_fast is not exported"
    jsr = bytes([0x20, fast & 0xFF, fast >> 8])
    assert jsr in body, \
        "nothing calls kl_fast -- the dispatch never tries the Epyx path"
    assert bytes([0x4C, 0xB8, 0xF4]) in body, \
        "the fallback to the stock serial loader ($F4B8) is gone; without it a " \
        "drive that cannot do Epyx has no way to load at all"

    # SA=0 ("load at the caller's X/Y") must be handled, not refused. The Epyx
    # stream always carries the file's own address, so honouring that form means
    # overriding the destination with MEMUSS ($C3/$C4) -- which is what puts us
    # ahead of the real cartridge, since it declines and stays slow in `,8`.
    assert bytes([0xA5, 0xB9]) in body, "the receiver never reads SA ($B9)"
    assert bytes([0xA5, 0xC3]) in body and bytes([0xA5, 0xC4]) in body, \
        "MEMUSS ($C3/$C4) is never read -- a LOAD\"x\",8 would land at the " \
        "file's own address instead of where the caller asked"

    # The stock LOAD messages. Both routines gate on MSGFLG themselves, so a
    # running program still gets silence -- but without them a BASIC LOAD in
    # direct mode would go quiet, which is a visible change in behaviour.
    assert bytes([0x20, 0xAF, 0xF5]) in body, \
        "SEARCHING ($F5AF) is not printed"
    assert bytes([0x20, 0xD2, 0xF5]) in body, \
        "LOADING ($F5D2) is not printed"

    # The stock vector-table entry it repoints, read from the real image rather
    # than trusted: $FD4C must currently hold $F4A5 (the stock ILOAD).
    stock = os.path.join(_BUILD, "..", "stock-roms", "kernal.901227-03.bin")
    if os.path.exists(stock):
        rom = open(stock, "rb").read()
        off = 0xFD4C - 0xE000
        assert rom[off] | (rom[off + 1] << 8) == 0xF4A5, \
            "the ILOAD entry at $FD4C is not $F4A5 in this KERNAL -- the vector " \
            "table moved, so the poke offsets are wrong"


def test_exit_wedge_targets_the_real_escape(v):
    """`EXIT` in stock BASIC must jump to where the swap-back actually is.

    The wedge is linked separately (cfg/kload.cfg) and cannot import
    rbcp_escape_tramp, so kload.s hardcodes its RUN address. That is a
    cross-link constant with nothing holding it together: move RBCP_CODE by a
    byte and `EXIT` jumps into the middle of some other routine, under stock
    ROMs, with no way to tell what happened. Pin it here instead.
    """
    (void) = v

    # The address is POKED in, not hardcoded -- so what there is to check is
    # that the wedge jumps INDIRECTLY through its own vector, and that the
    # trampoline fills that vector from the real symbol.
    src = _read("src", "kload.s")
    assert "jmp (escape_vec)" in src, \
        "the EXIT wedge no longer jumps through escape_vec -- if it hardcodes " \
        "an address again, it will go stale the next time RBCP_CODE moves"
    launch = _read("src", "rbcp", "launch.s")
    assert "<rbcp_escape_tramp, >rbcp_escape_tramp" in launch, \
        "the swap trampoline does not poke the escape address into the wedge"

    # ...and that it is actually reached: the wedge must be in the poked image,
    # and BASIC's IGONE table entry ($E44F, slot offset $044F) repointed at it.
    size = os.path.getsize(os.path.join(_BUILD, "kload3.bin"))
    assert 0xF533 + size - 1 <= 0xF5A8, \
        "the EXIT wedge is %d bytes and overruns its tape run at $F5A8" % size

    stock = os.path.join(_BUILD, "..", "stock-roms", "kernal.901227-03.bin")
    if os.path.exists(stock):
        rom = open(stock, "rb").read()
        off = 0xE44F - 0xE000
        assert rom[off] | (rom[off + 1] << 8) == 0xA7E4, \
            "BASIC's IGONE entry at $E44F is not $A7E4 in this KERNAL -- the " \
            "vector table moved, so the poke offset is wrong"

    assert "$4C, $4D, $4F, $50, $33, $34" in launch, \
        "the vector-patch table must carry ILOAD ($4C/$4D), IGONE ($4F/$50) " \
        "and the wedge's escape vector ($33/$34)"


def test_basic_command_text_area_agrees_between_the_two_sides(v):
    """`basic <command>` passes a line to the stub through fixed addresses.

    fs.c writes it and the stub (c_io.s) reads it, with nothing linking the two
    but matching literals -- and it cannot be exercised in VICE, since the swap
    is inert and the planted CBM80 would have our own reset relaunch the stub in
    a loop. So check the contract statically: same addresses, a text area that
    clears both the stub and RUN_PARAMS, and a length that the keyboard buffer
    can actually hold.
    """
    (void) = v

    asm = _read("src", "c_io.s")
    c = _read("src", "commands", "fs.c")

    def const(text, name, pat):
        m = re.search(pat, text)
        assert m, "%s not found" % name
        return int(m.group(1), 16)

    tlen_asm = const(asm, "RUN_TLEN (asm)", r"RUN_TLEN\s*=\s*\$([0-9A-Fa-f]{4})")
    text_asm = const(asm, "RUN_TEXT (asm)", r"RUN_TEXT\s*=\s*\$([0-9A-Fa-f]{4})")
    tlen_c = const(c, "RUN_TLEN (C)", r"RUN_TLEN.*?0x([0-9A-Fa-f]{4})")
    text_c = const(c, "RUN_TEXT (C)", r"RUN_TEXT.*?0x([0-9A-Fa-f]{4})")

    assert tlen_asm == tlen_c, \
        "RUN_TLEN is $%04X in c_io.s but $%04X in fs.c" % (tlen_asm, tlen_c)
    assert text_asm == text_c, \
        "RUN_TEXT is $%04X in c_io.s but $%04X in fs.c" % (text_asm, text_c)

    m = re.search(r"#define RUN_TMAX\s+(\d+)", c)
    assert m, "RUN_TMAX not found"
    tmax = int(m.group(1))
    assert tmax <= 10, \
        "RUN_TMAX is %d, but the keyboard buffer at $0277 holds 10" % tmax

    # The text must sit clear of the stub below it and RUN_PARAMS above it.
    L = _labels()
    end = 0xCF00 + (L["_run_stub_end"] - L["_run_stub"])
    assert tlen_asm >= end, \
        "the text area starts at $%04X but the stub runs to $%04X -- copying " \
        "the stub would overwrite the command" % (tlen_asm, end - 1)
    assert text_asm + tmax <= 0xCFF8, \
        "the text area runs to $%04X and would collide with RUN_PARAMS at $CFF8" \
        % (text_asm + tmax - 1)

    # And the stub must actually branch on mode 2, or the text is never typed.
    assert re.search(r"lda RUN_MODE\s*\n\s*cmp #2", asm), \
        "the stub no longer tests for mode 2"


def test_run_stub_has_no_absolute_jumps_into_our_rom(v):
    """The stub is assembled in our ROM but RUNS at $CF00 after being copied.

    So every internal jump must be relocated (RUN_STUB_BASE + offset) or stay a
    PC-relative branch. A plain `jmp @label` assembles the ROM address and, once
    copied, jumps into our KERNAL -- which by then has been swapped away for the
    stock ROMs, so it lands in whatever stock code occupies that address. This
    caught exactly that: `jmp @ml` became `JMP $E9C2`.
    """
    (void) = v

    L = _labels()
    lo, hi = L["_run_stub"], L["_run_stub_end"]
    rom = open(os.path.join(_BUILD, "kernal.bin"), "rb").read()
    stub = rom[lo - 0xE000:hi - 0xE000]

    bad = []
    i = 0
    while i < len(stub) - 2:
        if stub[i] in (0x4C, 0x20):             # JMP abs / JSR abs
            t = stub[i + 1] | (stub[i + 2] << 8)
            if lo <= t < hi:                    # a target inside the stub's own
                bad.append((0xCF00 + i, t))     # ROM image = unrelocated
        i += 1
    assert not bad, \
        "unrelocated internal jumps in the run stub: %s -- use " \
        "RUN_STUB_BASE + (label - _run_stub)" \
        % ", ".join("$%04X -> $%04X" % (a, t) for a, t in bad)
