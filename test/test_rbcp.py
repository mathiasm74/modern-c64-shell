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

_LABELS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "build", "labels.txt")


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
    assert rom_first == 0xAD, "expected library to start with LDA absolute ($AD)"


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


def test_overlay_command_fails_gracefully_without_device(v):
    # `about` is the first overlay command: its code is NOT in the shell ROM
    # (it lives in the One ROM's overlays flash set), and the resident thunk
    # fetches it through the same RBCP session machinery as tardis. In VICE
    # no device answers, so the thunk must report the stage-1 enter failure
    # rather than jumping into an unfilled cache page.
    v.run_for(0.3)
    v.write_memory(0x0277, [ord(c) for c in "about"] + [0x0D])
    v.write_byte(0x00C6, 6)
    for _ in range(10):
        v.run_for(0.5)
        if "overlay load failed, stage 1" in v.screen_text():
            break
    assert "overlay load failed, stage 1" in v.screen_text(), \
        "about did not report the expected overlay-load failure\n%s" % v.screen_text()


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
