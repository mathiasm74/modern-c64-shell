"""Disk I/O over the IEC serial bus (Phase 6/8).

These run with test/data/test.d64 mounted on device 8 under true drive
emulation -- the only path that works once we've replaced the KERNAL, since
VICE's virtual-device traps hook KERNAL addresses that no longer exist. See
test/data/make_test_disk.sh for the fixture (prog, readme, doc).

Directory commands clear the screen first so a `in screen` assertion can't
match a previous command's output still on screen.
"""

VICE_DISK = "data/test.d64"

CLEAR = 0x93


def _type(v, text, clear=False):
    codes = ([CLEAR] if clear else []) + [ord(c) for c in text] + [0x0D]
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))


def _wait_for(v, needle, tries=20, chunk=0.8):
    """Run in short bursts until `needle` appears on screen, or give up.

    Disk transfers take real (emulated) 1541 time that varies under warp (and
    with host load), so poll generously rather than race a fixed sleep."""
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


def test_dir_lists_directory(v):
    # "dir" is the full 1541-style listing: block counts, names, types, free.
    _type(v, "dir", clear=True)
    done = _wait_for(v, "BLOCKS FREE")
    txt = v.screen_text()
    assert done, "dir never finished (no blocks-free line)\n%s" % txt
    assert "PROG" in txt and "README" in txt, "dir missing files\n%s" % txt
    assert v.pc() is not None and 0xA000 <= v.pc() <= 0xFFFF, \
        "shell not back in ROM after dir"


def test_ls_colors_names_by_type(v):
    # "ls" lists just the names, each colored by type. PROG/README are PRG and
    # DOC is SEQ, so the PRG and SEQ names get different text colors.
    _type(v, "ls", clear=True)
    assert _wait_for(v, "DOC"), "ls did not list the files"
    rows = v.screen_rows()

    def color_at(name):
        for i, r in enumerate(rows):
            if r.strip() == name:               # ls prints the bare name
                return v.read_byte(0xD800 + i * 40) & 0x0F
        return None

    prg = color_at("PROG")
    seq = color_at("DOC")
    assert prg is not None and seq is not None, "ls names not found as bare lines"
    assert prg != seq, "PRG and SEQ names share a color (%d vs %d)" % (prg, seq)


def test_pwd_prints_device_and_disk_name(v):
    # pwd prefixes the current device (8, no name set here) before the title.
    _type(v, "pwd", clear=True)
    assert _wait_for(v, "TEST DISK"), "pwd did not print the disk name"
    assert "8: TEST DISK" in v.screen_text(), \
        "pwd did not prefix the device number\n%s" % v.screen_text()


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
