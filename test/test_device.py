"""The `device` command (Phase 8).

`device <n> [name]` probes the bus before switching: if the unit doesn't
answer it reports "device <n> not present" and keeps the current device, so a
typo can't silently misdirect later commands. A name, if given for a present
unit, is remembered and recalled when `device <n>` is later given alone.

Runs with test.d64 on device 8 under true drive emulation (probing needs a
real drive to answer). Device 9 is deliberately absent. These commands are
read-only (the probe just opens "$"), so the tracked fixture is fine.
"""

from lib.overlays import seed_dir, seed_files

VICE_DISK = "data/test.d64"

CR = 0x0D
CLEAR = 0x93


def _ch(s):
    return [ord(c) for c in s]


def _type(v, text, clear=False):
    codes = ([CLEAR] if clear else []) + _ch(text) + [CR]
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))


def _wait_for(v, needle, tries=16, chunk=0.8):
    for _ in range(tries):
        v.run_for(chunk)
        if needle in v.screen_text():
            return True
    return False


def test_absent_device_reports_and_stays_put(v):
    # Only device 8 is on the bus. `device 9` must probe, find nothing, report
    # the numbered error, and -- crucially -- NOT switch: a directory on the
    # unchanged default (8) still works, proving we stayed put and that the
    # partial probe didn't poison the real drive. (Regression: the bus had no
    # send-path timeout, so this hung forever.)
    seed_files(v)                           # device is a files-overlay command
    _type(v, "device 9", clear=True)
    assert _wait_for(v, "device 9 not present"), \
        "absent device not reported with its number\n%s" % v.screen_text()
    pc = v.pc()
    assert pc is not None and (0xA000 <= pc <= 0xBFFF or 0xE000 <= pc <= 0xFFFF), \
        "shell not responsive (PC not in ROM) after the absent-device probe"

    seed_dir(v)
    _type(v, "dir", clear=True)
    assert _wait_for(v, "BLOCKS FREE"), \
        "default device 8 broke after the absent-device probe\n%s" % v.screen_text()


def test_device_names_present_device(v):
    # Naming works for a unit that's actually there: name 8 "fd" (split across
    # two keyboard-buffer loads -- "device 8 fd" is 11 chars), confirm, then
    # `device 8` alone recalls the name.
    seed_files(v)
    v.write_memory(0x0277, _ch("device 8 "))
    v.write_byte(0x00C6, 9)
    v.run_for(0.3)
    v.write_memory(0x0277, _ch("fd") + [CR])
    v.write_byte(0x00C6, 3)
    assert _wait_for(v, "device 8 fd"), \
        "device did not confirm the name for a present unit\n%s" % v.screen_text()

    seed_files(v)
    _type(v, "device 8", clear=True)        # no name given -> recalls "fd"
    assert _wait_for(v, "device 8 fd"), \
        "device 8 did not recall the remembered name\n%s" % v.screen_text()


def test_device_fetches_identity_for_prompt(v):
    # `device 8` with no name and nothing remembered asks the drive who it is
    # ("UI" + read channel 15) and shows that in the prompt INSTEAD of the
    # unit number: VICE's 1541 answers "73,CBM DOS V2.6 1541,00,00", which
    # maps to the short name "1541". (Named or remembered units skip the
    # fetch; this test runs -- alphabetically -- before the naming tests, so
    # unit 8's slot is still empty.)
    seed_files(v)                           # device is a files-overlay command
    _type(v, "device 8", clear=True)
    assert _wait_for(v, "device 8 1541"), \
        "device did not fetch/print the drive identity: %r" % v.screen_text()
    prompt = None
    for r in v.screen_rows():
        if r.strip().endswith(">"):
            prompt = r.strip()
    assert prompt == "8: 1541>", \
        "prompt should show number + identity, got %r" % prompt


def test_dev_alias(v):
    # "dev" is an alias for "device" (same handler, second dispatch entry).
    seed_files(v)
    _type(v, "dev 9", clear=True)
    assert _wait_for(v, "device 9 not present"), \
        "dev alias did not run the device command: %r" % v.screen_text()


def test_devices_scans_the_bus(v):
    # `devices` (files overlay cmd 18) probes units 8-15 in bounded probe
    # mode and prints each present drive's identity line. VICE has only the
    # 1541 on unit 8; the seven absent units must time out, not wedge.
    seed_files(v)
    _type(v, "devices", clear=True)
    assert _wait_for(v, "8: CBM DOS V2.6 1541", tries=30), \
        "devices did not list the 1541: %r" % v.screen_text()
    # the seven absent units are still being probed (a dot each, ~1s emulated
    # apiece); wait for the scan to finish before judging the final screen
    for _ in range(40):
        if "..." not in v.screen_text():
            break
        v.run_for(0.5)
    assert "9:" not in v.screen_text(), \
        "devices listed an absent unit: %r" % v.screen_text()
    assert "..." not in v.screen_text(), \
        "progress dots were not wiped after the scan: %r" % v.screen_text()
