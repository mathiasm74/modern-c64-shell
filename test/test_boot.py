"""Boot succeeds: the machine map is ours and the CPU is running our ROM."""


def test_processor_port_maps_roms(v):
    # $01 low 3 bits (LORAM/HIRAM/CHAREN) must all be set: shell ROM + KERNAL
    # ROM + I/O are mapped. A wrong value here means we mapped ourselves out.
    port = v.read_byte(0x01)
    assert port is not None and (port & 0x07) == 0x07, \
        "processor port $01=%s does not map ROMs+I/O" % (
            "$%02X" % port if port is not None else "?")


def test_reset_vector(v):
    # $FFFC/$FFFD must point at the reset entry at $E000.
    v.assert_memory_equals(0xFFFC, [0x00, 0xE0])


def test_cpu_running_in_rom(v):
    # After boot the CPU spins in the halt loop, which lives in KERNAL ROM.
    pc = v.pc()
    assert pc is not None and 0xE000 <= pc <= 0xFFFF, \
        "PC %s is not in KERNAL ROM (boot may have crashed)" % (
            "$%04X" % pc if pc is not None else "?")
