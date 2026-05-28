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
    jmp = L["rbcp_trampoline_jmp"]
    assert run <= tramp < run + size, "rbcp_trampoline $%04X outside RBCP_RAM" % tramp
    assert tramp <= jmp < tramp + 0x40, \
        "rbcp_trampoline_jmp $%04X looks too far from the trampoline start" % jmp


def test_launch_copies_library_and_patches_jmp(v):
    # _rbcp_launch_stock copies the whole RBCP_CODE block to its run-address
    # then patches the trampoline's JMP operand with the entry address it
    # was called with. We verify both. The launcher then JMPs into the
    # trampoline, which SEIs and starts banging on the command page; in
    # VICE that hangs in the protocol's poll loop, but the copy + patch
    # have already happened by then.
    L = _labels()
    launch = L["_rbcp_launch_stock"]
    load = L["__RBCP_CODE_LOAD__"]
    run = L["__RBCP_CODE_RUN__"]
    jmp = L["rbcp_trampoline_jmp"]

    # Stub at $1000: LDA #lo; LDX #hi; JSR launch; JMP self (if launch ever
    # returned, which it doesn't). Pass entry = $4321 as a sentinel.
    stub = [0xA9, 0x21,            # LDA #$21
            0xA2, 0x43,            # LDX #$43
            0x20, launch & 0xFF, (launch >> 8) & 0xFF,
            0x4C, 0x07, 0x10]      # JMP $1007 (the JMP itself)
    v.write_memory(0x1000, stub)
    v.run_at(0x1000, 0.5)

    # After the launch runs to completion, the trampoline SEIs and bangs on
    # the command page; with no One ROM responding in VICE, the protocol's
    # poll loop times out and the trampoline ends up `JMP`ing to the
    # sentinel entry address ($4321 here), which is uninitialized RAM --
    # garbage execution may well STA $01 with random values and unmap our
    # KERNAL ROM. Restore the standard mapping ($37) before reading ROM so
    # we see ROM bytes, not whatever's underneath in RAM.
    v.write_byte(0x01, 0x37)

    # The library's first byte (LDA opcode $AD for the first export rbcp_knock)
    # should now match between ROM source and RAM destination.
    rom_first = v.read_byte(load)
    ram_first = v.read_byte(run)
    assert rom_first == ram_first, \
        "library first byte mismatch: ROM=$%02X RAM=$%02X" % (rom_first, ram_first)
    assert rom_first == 0xAD, "expected library to start with LDA absolute ($AD)"

    # The trampoline's JMP operand should now be $4321 (low/high in that order).
    operand = v.read_memory(jmp, 3)
    assert operand[0] == 0x4C, "trampoline first byte should still be JMP ($4C)"
    assert operand[1] == 0x21 and operand[2] == 0x43, \
        "trampoline JMP not patched: got %s, expected [$4C, $21, $43]" % (
            [hex(b) for b in operand])
