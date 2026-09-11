"""Empty-IEC-bus behavior (VICE_ARGS removes drive 8 entirely).

`-drive8type 0` puts NOTHING on the bus -- the closest VICE gets to a yanked
cable. (Without it VICE's default drive 8 answers ATN even with no disk
attached, which is why these tests can't live in test_disk_nodrive.)

The scenario behind the probe test: fload's post-transfer presence probe
(fs.c fload_program) runs ~30ms after a mid-transfer cable pull, inside the
connector's contact bounce; a transient DATA-low faked the presence gate and
iec_sendbyte's then-unbounded under-ATN handshakes wedged the machine until
the cable returned (whereupon the drive's ATN response supplied the missing
ack and fload reported phantom success). The under-ATN waits are bounded now
(hs_ack in iec.s); the bounce itself can't be scripted in VICE, but
the empty-bus probe must come back fast with NODEV and release every line.
"""

import os

from lib.overlays import seed_disk_bank   # `load` lives in the disk bank now

VICE_ARGS = ["-drive8type", "0"]

_LABELS = os.path.join(os.path.dirname(__file__), "..", "build", "labels.txt")


def _label_addr(name):
    with open(_LABELS) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 3 and parts[2].lstrip(".") == name:
                return int(parts[1], 16) & 0xFFFF
    raise AssertionError("label %r not found in %s" % (name, _LABELS))


def _wait_boot(v):
    for _ in range(30):
        if "Ready." in v.screen_text():
            return
        v.run_for(0.3)
    raise AssertionError("shell never booted")


def test_presence_probe_fails_fast_and_releases_lines(v):
    # The exact probe sequence fload_program runs after a transfer:
    # iec_set_fa(8), iec_set_sa(15), iec_chkin(), iec_clrchn(), then ST.
    _wait_boot(v)
    setfa = _label_addr("_iec_set_fa")
    setsa = _label_addr("_iec_set_sa")
    chkin = _label_addr("_iec_chkin")
    clrch = _label_addr("_iec_clrchn")
    stub = ([0xA9, 0x08, 0xA2, 0x00, 0x20, setfa & 0xFF, setfa >> 8]
            + [0xA9, 0x0F, 0xA2, 0x00, 0x20, setsa & 0xFF, setsa >> 8]
            + [0x20, chkin & 0xFF, chkin >> 8]
            + [0x20, clrch & 0xFF, clrch >> 8]
            + [0xA5, 0x90, 0x8D, 0xF0, 0x10]        # ST -> $10F0
            + [0xA9, 0x01, 0x8D, 0xF2, 0x10]        # done marker
            + [0x4C, 0x1E, 0x10])                   # spin
    v.write_memory(0x1000, stub)
    v.write_memory(0x10F0, [0xEE, 0xEE, 0xEE])
    v.run_at(0x1000, 0.5)
    # every wait in the path is bounded; the whole probe is well under ~3s
    for _ in range(8):
        if v.read_byte(0x10F2) == 0x01:
            break
        v.run_for(0.5)
    assert v.read_byte(0x10F2) == 0x01, "probe wedged on an empty bus"
    st = v.read_byte(0x10F0)
    assert st & 0x82, "probe on an empty bus must set NODEV/TIMEOUT, ST=$%02X" % st
    # clrchn must have released ATN/CLK/DATA (output bits 3-5 of $DD00 clear)
    dd00 = v.read_byte(0xDD00)
    assert (dd00 & 0x38) == 0, "IEC lines still held after probe, $DD00=$%02X" % dd00


def test_load_reports_no_device_promptly(v):
    seed_disk_bank(v)
    # `load` is resident and drives IEC directly (`ls`/`dir` are overlay
    # commands and die at the RBCP fetch on VICE before touching the bus).
    _wait_boot(v)
    v.inject_keys("load x\r")   # short: the keyboard buffer caps at 10 chars
    for _ in range(20):
        if "not present" in v.screen_text():
            return
        v.run_for(0.5)
    raise AssertionError("load on an empty bus never reported a missing device: %r"
                         % v.screen_text())
