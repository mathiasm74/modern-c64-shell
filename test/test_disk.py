"""Disk I/O over the IEC serial bus (Phase 6).

These run with test/data/test.d64 mounted on device 8 under true drive
emulation -- the only path that works once we've replaced the KERNAL, since
VICE's virtual-device traps hook KERNAL addresses that no longer exist. See
test/data/make_test_disk.sh for the fixture's contents (files "hello" and
"readme").

For now this just guards the harness plumbing: that attaching the drive
doesn't disturb a clean boot. The ls/load/run assertions arrive with the IEC
implementation.
"""

VICE_DISK = "data/test.d64"


def test_boots_clean_with_drive_attached(v):
    # Attaching a true-drive 1541 must not perturb the boot: the shell prompt
    # is up and the CPU is running in ROM, same as without a disk.
    assert "> " in v.screen_text(), "shell prompt not on screen with drive attached"
    pc = v.pc()
    in_rom = pc is not None and (0xA000 <= pc <= 0xBFFF or 0xE000 <= pc <= 0xFFFF)
    assert in_rom, "PC %s not in ROM after boot with drive attached" % (
        "$%04X" % pc if pc is not None else "?")
