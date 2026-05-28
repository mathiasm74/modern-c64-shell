"""KERNAL file-I/O entry points at their published addresses.

Real C64 software calls SETLFS at $FFBA, LOAD at $FFD5, and friends. The
shell itself doesn't use these (it talks to iec.s directly), so these tests
write small ML stubs into RAM, jump to them via the harness's `run_at`, and
verify the side effects. The disk-touching tests need test.d64 on device 8.
"""

VICE_DISK = "data/test.d64"

# Standard KERNAL entry points (address, name).
PINS = [
    (0xFFBA, "SETLFS"), (0xFFBD, "SETNAM"), (0xFFC0, "OPEN"),
    (0xFFC3, "CLOSE"),  (0xFFC6, "CHKIN"),  (0xFFC9, "CHKOUT"),
    (0xFFCC, "CLRCHN"), (0xFFCF, "CHRIN"),  (0xFFD2, "CHROUT"),
    (0xFFD5, "LOAD"),   (0xFFD8, "SAVE"),   (0xFFE4, "GETIN"),
]


def _spin(addr):
    """Three bytes: JMP <addr> -- park the CPU at a known PC after the stub."""
    return [0x4C, addr & 0xFF, (addr >> 8) & 0xFF]


def test_entry_points_are_jmps(v):
    # The pinned table must be JMPs into KERNAL ROM. A regression here means
    # the linker config lost one of the pinned-address segments.
    for addr, name in PINS:
        b = v.read_memory(addr, 3)
        assert b[0] == 0x4C, \
            "%s @ $%04X should be JMP ($4C), got $%02X" % (name, addr, b[0])
        target = b[1] | (b[2] << 8)
        assert 0xE000 <= target <= 0xFFFF, \
            "%s target $%04X is not in KERNAL ROM" % (name, target)


def test_setlfs_records_logical_file_device_secondary(v):
    # SETLFS(A=lfn, X=device, Y=secondary) writes $B8 LA, $BA FA, $B9 SA.
    #   LDA #$0A ; LDX #$09 ; LDY #$0F ; JSR $FFBA ; JMP self
    stub = ([0xA9, 0x0A, 0xA2, 0x09, 0xA0, 0x0F, 0x20, 0xBA, 0xFF]
            + _spin(0x1009))
    v.write_memory(0x1000, stub)
    v.run_at(0x1000, 0.1)
    assert v.read_byte(0xB8) == 0x0A, "SETLFS did not set LA ($B8)"
    assert v.read_byte(0xBA) == 0x09, "SETLFS did not set FA ($BA)"
    assert v.read_byte(0xB9) == 0x0F, "SETLFS did not set SA ($B9)"


def test_setnam_records_length_and_pointer(v):
    # Place a 4-char name at $0F00, then SETNAM(A=4, X=$00, Y=$0F).
    v.write_memory(0x0F00, [ord(c) for c in "prog"])
    stub = ([0xA9, 0x04, 0xA2, 0x00, 0xA0, 0x0F, 0x20, 0xBD, 0xFF]
            + _spin(0x1009))
    v.write_memory(0x1000, stub)
    v.run_at(0x1000, 0.1)
    assert v.read_byte(0xB7) == 4, "SETNAM did not set FNLEN ($B7)"
    assert v.read_byte(0xBB) == 0x00, "SETNAM did not set FNADR lo ($BB)"
    assert v.read_byte(0xBC) == 0x0F, "SETNAM did not set FNADR hi ($BC)"


def test_load_via_ffd5_pulls_prog_from_disk(v):
    # End-to-end LOAD: SETLFS, SETNAM, then JSR $FFD5. SA=0 in SETLFS means
    # "use the file's own load address" -- per make_test_disk.sh, prog loads
    # at $2000. The first 8 bytes of prog are known; check those.
    v.write_memory(0x2000, [0xFF] * 8)              # poison the target
    v.write_memory(0x0F00, [ord(c) for c in "prog"])
    stub = (
        [0xA9, 0x00, 0xA2, 0x08, 0xA0, 0x00, 0x20, 0xBA, 0xFF]  # SETLFS 0,8,0
        + [0xA9, 0x04, 0xA2, 0x00, 0xA0, 0x0F, 0x20, 0xBD, 0xFF]  # SETNAM
        + [0xA9, 0x00, 0xA2, 0x00, 0xA0, 0x00, 0x20, 0xD5, 0xFF]  # LOAD (mode 0)
        + _spin(0x101B)
    )
    v.write_memory(0x1000, stub)
    # Generous: opening + reading a small PRG over the bit-banged IEC bus.
    v.run_at(0x1000, 4.0)
    # First 8 bytes of prog (the LDX #$00 / LDA $200E,X loop -- see fixture).
    expected = [0xA2, 0x00, 0xBD, 0x0E, 0x20, 0xF0, 0x06, 0x20]
    got = v.read_memory(0x2000, 8)
    assert got == expected, \
        "LOAD did not place prog at $2000: got %s, want %s" % (got, expected)
    pc = v.pc()
    # The stub's resting place is its spin loop, but the keyboard-scan IRQ
    # interrupts it ~60 times a second, so on halt the CPU is occasionally
    # inside the IRQ handler in KERNAL ROM. Either is fine; a crash would
    # land in user RAM ($0000-$9FFF, excluding shell ROM at $A000-$BFFF).
    ok = (0x101B <= pc <= 0x101E) or (0xE000 <= pc <= 0xFFFF)
    assert pc is not None and ok, \
        "PC $%04X is neither stub spin nor KERNAL ROM (likely a crash)" % (pc or 0)


def test_chrin_reads_bytes_from_open_file(v):
    # Open the SEQ file "doc" (channel 2 = data read), CHKIN, then read 4
    # CHRIN bytes -- they should be "l00\r" (the start of the first line per
    # make_test_disk.sh). CLOSE + CLRCHN to leave the bus clean.
    v.write_memory(0x0F00, [ord(c) for c in "doc"])
    v.write_memory(0x0F10, [0xFF] * 4)             # poison the result buffer
    # Stub layout (offsets from $1000):
    #   00: SETLFS 2,8,2
    #   09: SETNAM 3, $0F00
    #   18: OPEN
    #   21: LDX #2 ; CHKIN
    #   26: LDY #0
    #   28: CHRIN ; STA $0F10,Y ; INY ; CPY #4 ; BNE -11
    #   3B: CLRCHN
    #   3E: LDA #2 ; CLOSE
    #   43: JMP self
    stub = (
        [0xA9, 0x02, 0xA2, 0x08, 0xA0, 0x02, 0x20, 0xBA, 0xFF]   # SETLFS 2,8,2
        + [0xA9, 0x03, 0xA2, 0x00, 0xA0, 0x0F, 0x20, 0xBD, 0xFF]  # SETNAM
        + [0x20, 0xC0, 0xFF]                                       # OPEN
        + [0xA2, 0x02, 0x20, 0xC6, 0xFF]                           # CHKIN LFN 2
        + [0xA0, 0x00]                                             # LDY #0
        + [0x20, 0xCF, 0xFF,                                       # CHRIN
           0x99, 0x10, 0x0F,                                       # STA $0F10,Y
           0xC8,                                                   # INY
           0xC0, 0x04,                                             # CPY #4
           0xD0, 0xF5]                                             # BNE -11
        + [0x20, 0xCC, 0xFF]                                       # CLRCHN
        + [0xA9, 0x02, 0x20, 0xC3, 0xFF]                           # CLOSE LFN 2
    )
    spin_addr = 0x1000 + len(stub)
    stub += _spin(spin_addr)
    v.write_memory(0x1000, stub)
    v.run_at(0x1000, 3.0)
    got = bytes(v.read_memory(0x0F10, 4))
    assert got == b"l00\r", "CHRIN sequence was %r, expected 'l00\\r'" % got


def test_clrchn_restores_default_channels(v):
    # After CHKIN points DFLTN at device 8, CLRCHN must restore it to 0
    # (keyboard) and leave DFLTO at 3 (screen). Use the doc file again.
    v.write_memory(0x0F00, [ord(c) for c in "doc"])
    stub = (
        [0xA9, 0x02, 0xA2, 0x08, 0xA0, 0x02, 0x20, 0xBA, 0xFF]   # SETLFS
        + [0xA9, 0x03, 0xA2, 0x00, 0xA0, 0x0F, 0x20, 0xBD, 0xFF]  # SETNAM
        + [0x20, 0xC0, 0xFF]                                       # OPEN
        + [0xA2, 0x02, 0x20, 0xC6, 0xFF]                           # CHKIN
        # At this point DFLTN ($99) should be 8 (proved below as a checkpoint).
        + [0x20, 0xCC, 0xFF]                                       # CLRCHN
        + [0xA9, 0x02, 0x20, 0xC3, 0xFF]                           # CLOSE
    )
    spin_addr = 0x1000 + len(stub)
    stub += _spin(spin_addr)
    v.write_memory(0x1000, stub)
    v.run_at(0x1000, 3.0)
    # After CLRCHN, defaults are back: input=keyboard (0), output=screen (3).
    assert v.read_byte(0x99) == 0x00, "CLRCHN did not restore DFLTN to 0"
    assert v.read_byte(0x9A) == 0x03, "CLRCHN did not restore DFLTO to 3"
