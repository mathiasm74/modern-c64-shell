"""Disk I/O over the IEC serial bus (Phase 6).

These run with test/data/test.d64 mounted on device 8 under true drive
emulation -- the only path that works once we've replaced the KERNAL, since
VICE's virtual-device traps hook KERNAL addresses that no longer exist. See
test/data/make_test_disk.sh for the fixture's contents (files "hello" and
"readme").

"""

VICE_DISK = "data/test.d64"


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [0x0D])
    v.write_byte(0x00C6, len(text) + 1)


def _wait_for(v, needle, tries=10, chunk=0.8):
    """Run in short bursts until `needle` appears on screen, or give up.

    Disk transfers take real (emulated) 1541 time that varies under warp, so
    poll rather than race a fixed sleep."""
    for _ in range(tries):
        v.run_for(chunk)
        if needle in v.screen_text():
            return True
    return False


def test_boots_clean_with_drive_attached(v):
    # Attaching a true-drive 1541 must not perturb the boot: the shell prompt
    # is up and the CPU is running in ROM, same as without a disk.
    assert "> " in v.screen_text(), "shell prompt not on screen with drive attached"
    pc = v.pc()
    in_rom = pc is not None and (0xA000 <= pc <= 0xBFFF or 0xE000 <= pc <= 0xFFFF)
    assert in_rom, "PC %s not in ROM after boot with drive attached" % (
        "$%04X" % pc if pc is not None else "?")


def test_ls_lists_directory(v):
    # "ls" reads the directory over the IEC bus and prints it.
    _type(v, "ls")
    done = _wait_for(v, "BLOCKS FREE")
    txt = v.screen_text()
    assert done, "ls never finished (no blocks-free line)\n%s" % txt
    assert "PROG" in txt, "ls did not list PROG\n%s" % txt
    assert "README" in txt, "ls did not list README"
    # The shell must survive the transfer and return to a prompt.
    assert v.pc() is not None and 0xA000 <= v.pc() <= 0xFFFF, \
        "shell not back in ROM after ls"


def test_load_into_memory(v):
    # "load prog" reads the PRG to its load address ($2000) and reports the
    # range, but does not start it (non-destructive: shell stays at a prompt).
    _type(v, "load prog")
    done = _wait_for(v, "loaded $")
    txt = v.screen_text()
    assert done, "load did not report success\n%s" % txt
    assert "$2000-$201e" in txt, "load reported the wrong range\n%s" % txt
    assert v.read_memory(0x2000, 8) == [0xA2, 0x00, 0xBD, 0x0E, 0x20, 0xF0, 0x06, 0x20], \
        "loaded program bytes wrong at $2000"
