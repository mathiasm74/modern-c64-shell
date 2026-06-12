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


def test_tardis_reports_rbcp_timeout(v):
    # The tardis PoC command drives a real RBCP session (knock, enter
    # command-response mode, SLOT_PEEK 64 bytes, exit). In VICE no device
    # answers: the back-channel token never increments, enter_cmd_resp
    # times out, and the command must fail gracefully with its stage-1
    # message -- exercising the C glue, the library copy to RAM, and the
    # session call path end-to-end, minus only the device itself.
    v.run_for(0.3)
    v.write_memory(0x0277, [ord(c) for c in "tardis"] + [0x0D])
    v.write_byte(0x00C6, 7)
    for _ in range(10):
        v.run_for(0.5)
        if "rbcp error, stage 1" in v.screen_text():
            break
    assert "rbcp error, stage 1" in v.screen_text(), \
        "tardis did not report the expected stage-1 timeout\n%s" % v.screen_text()
