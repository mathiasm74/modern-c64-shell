"""Disk I/O over the IEC serial bus (Phase 6/8).

These run with test/data/test.d64 mounted on device 8 under true drive
emulation -- the only path that works once we've replaced the KERNAL, since
VICE's virtual-device traps hook KERNAL addresses that no longer exist. See
test/data/make_test_disk.sh for the fixture (prog, readme, doc).

Directory commands clear the screen first so a `in screen` assertion can't
match a previous command's output still on screen.
"""

VICE_DISK = "data/test.d64"

from lib.overlays import seed_disk_bank

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
    seed_disk_bank(v)
    _type(v, "dir", clear=True)
    done = _wait_for(v, "BLOCKS FREE")
    txt = v.screen_text()
    assert done, "dir never finished (no blocks-free line)\n%s" % txt
    assert "PROG" in txt and "README" in txt, "dir missing files\n%s" % txt
    assert v.pc() is not None and 0xA000 <= v.pc() <= 0xFFFF, \
        "shell not back in ROM after dir"


def test_ls_colors_names_by_type(v):
    # "ls" lists just the names in two columns, each colored by type.
    # PROG/README are PRG and DOC is SEQ, so PRG/SEQ names get different colors.
    seed_disk_bank(v)
    _type(v, "ls", clear=True)
    assert _wait_for(v, "DOC"), "ls did not list the files"
    rows = v.screen_rows()

    def color_at(name):
        # ls packs names into two columns at offsets 0 and 20; find the name at
        # a column start (followed by a space/end) and read its first cell color.
        for i, r in enumerate(rows):
            for off in (0, 20):
                if r[off:off + len(name)] == name and \
                        r[off + len(name):off + len(name) + 1] in (" ", ""):
                    return v.read_byte(0xD800 + i * 40 + off) & 0x0F
        return None

    prg = color_at("PROG")
    seq = color_at("DOC")
    assert prg is not None and seq is not None, "ls names not found as bare lines"
    assert prg != seq, "PRG and SEQ names share a color (%d vs %d)" % (prg, seq)
    # Lock the type_color contract (src/overlays/dir.c): PRG light green, SEQ
    # cyan. The navigable kinds DIR and URL share yellow (0x07) so directories
    # read like the links you can also cd into -- but a 1541 image has no DIR
    # entries, so that pairing is hardware-verified, not asserted here.
    assert prg == 0x0D, "PRG should be light green, got %d" % prg
    assert seq == 0x03, "SEQ should be cyan, got %d" % seq


def test_pwd_prints_disk_name(v):
    # On the 1541 (which SYNTAX-ERRORs the PWD command) pwd falls back to the
    # header and prints just the disk title -- the device/name are already in
    # the prompt, so pwd no longer repeats them.
    seed_disk_bank(v)
    _type(v, "pwd", clear=True)
    assert _wait_for(v, "TEST DISK"), "pwd did not print the disk name"


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


def test_ls_fills_tab_completion_cache(v):
    # docs/TAB-COMPLETION.md: ls fills the $CE00 name cache as it draws and
    # validates it on a clean end; readline completes from it.
    from lib.overlays import seed_disk_bank
    seed_disk_bank(v)
    v.write_memory(0xCE00, [0, 0])
    _type(v, "ls")
    _wait_for(v, "prog")
    assert v.read_byte(0xCE00) == 1, "ls did not validate the cache"
    count = v.read_byte(0xCE01)
    assert count >= 3, "expected >= 3 cached names, got %d" % count
    # walk the packed entries looking for PROG
    data = v.read_memory(0xCE02, 253)
    names, off = [], 0
    while off < 250:
        n = data[off]
        if n == 0 or n > 16:
            break
        names.append("".join(chr(c) for c in data[off + 1:off + 1 + n]))
        off += 1 + n
    assert "PROG" in names, "PROG not in cache: %r" % names


def test_wedge_aliases(v):
    # JiffyDOS-style wedges are rewritten before parsing: "@$" = dir,
    # "/x" (and "%x") = load x, "@" = status, "@#<n>" = device <n>.
    # ("^x" = run x swaps to the stock ROMs -- hardware-only, not driven here.)
    from lib.overlays import seed_disk_bank, seed_files
    seed_disk_bank(v)
    _type(v, "@$", clear=True)
    assert _wait_for(v, "BLOCKS FREE"), \
        "@$ did not run dir: %r" % v.screen_text()
    _type(v, "/prog", clear=True)
    assert _wait_for(v, "loaded $2000"), \
        "/prog did not run load: %r" % v.screen_text()
    seed_files(v)
    _type(v, "@", clear=True)
    assert _wait_for(v, " OK"), \
        "@ did not run status: %r" % v.screen_text()
    seed_files(v)
    _type(v, "@#9", clear=True)
    assert _wait_for(v, "device 9 not present"), \
        "@#9 did not run device: %r" % v.screen_text()


def test_bank_call_invalidates_the_overlay_cache(v):
    """A bank call must invalidate the RAM overlay cached at $8800.

    The bank's per-entry init writes $9800-$9FFF (its DATA, BSS and C stack),
    which is the TAIL of every RAM overlay -- but the cache is validated only by
    the magic at $8803, BELOW that, so it survives intact. Without the explicit
    invalidate in bank_gosub (src/rbcp/launch.s) the next overlay command trusts
    a cache whose upper third is rubble and calls into it.

    This was a real hardware bug (v0.1.89): `cd` failed most of the time while
    `bg`/`border`/`text`/`help` -- the same overlay, but lower in it -- worked.
    VICE never caught it because tests re-seed between commands, so assert the
    invalidation directly.
    """
    from lib.overlays import seed_files

    seed_files(v)
    v.run_for(0.2)
    assert bytes(v.read_memory(0x8803, 4)) == b"fil1", "seeding did not take"

    seed_disk_bank(v)
    _type(v, "pwd", clear=True)
    _wait_for(v, ":")                   # let the bank call run

    assert bytes(v.read_memory(0x8803, 4)) != b"fil1", \
        "overlay magic survived a bank call -- the next overlay command would " \
        "run a cache whose $9800+ pages the bank just overwrote"
