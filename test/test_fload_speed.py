"""`fload` on a real 1541 keeps pace with the Epyx FastLoad cartridge.

Measured in VICE with true drive emulation, same disk, same file (16KB, 65
sectors at the standard interleave), both timed from RETURN to the file's last
byte landing:

                    16KB      1 sector
    Epyx v3 cart    9.28 s    2.07 s
    fload, v0.2.48  21.49 s   3.25 s
    fload, now      ~9.0 s    ~2.0 s

What closed it, and what each of these tests catches if it comes undone:

* THE CONTROLLER TICK. The 1541 runs its job queue from a 14.8 ms timer IRQ;
  src/drive1541.s now reloads that timer when it posts a read, as the cart
  does, so the job starts in 256 us instead of up to a tick later.
  (21.5 -> 13.6 s)
* THE BADLINE GATE blocks two raster offsets, not three (src/fastload_recv.s,
  badtab). The third cost ~22 cycles a byte of stall, took a sector's transmit
  from 31 to 37 ms, and made every other sector miss the interleave and wait a
  whole revolution. (13.6 -> 10.3 s)
* SETUP: no `I0`; a 78-byte bootstrap M-W'd up that fast-clocks the 454-byte
  loader in (src/drive1541_boot.s) instead of 15 M-Ws of it; and a seek to the
  directory track posted before the upload, so the motor spins up during it.
  (3.25 -> 2.0 s on a one-sector file)

Each threshold sits between the good figure and the nearest regression. The
tick kick, the badline gate and the seek were each reverted to check that the
test fails without them (20.2 s, 12.2 s and 2.22 s).

Timing is exact: a store watchpoint on the last byte stops the emulator there,
and the C64 stopwatch gives the cycles. Polling in warp would overshoot by
seconds of emulated time.
"""

import os
import random
import re
import shutil
import socket
import subprocess
import time

from lib.overlays import seed_disk_bank

_HERE = os.path.dirname(os.path.abspath(__file__))
_DISK = os.path.join(_HERE, "data", "_scratch_speed.d64")
PAL_HZ = 985248.0
BASE = 0x2000


def _payload(n, seed):
    rnd = random.Random(seed)
    return bytes(rnd.randrange(256) for _ in range(n))


BIG = _payload(16384, 1)                 # 65 sectors with its load address
ONE = _payload(200, 2)                   # one sector


def _make_disk():
    """A fresh disk with both files, written by c1541 at the standard
    interleave -- the layout a real 1541 SAVE produces."""
    c1541 = shutil.which("c1541")
    if not c1541:
        return False
    tmp = _DISK + ".d"
    os.makedirs(tmp, exist_ok=True)
    for name, data in (("big", BIG), ("one", ONE)):
        with open(os.path.join(tmp, name), "wb") as f:
            f.write(bytes([BASE & 0xFF, BASE >> 8]) + data)
    if os.path.exists(_DISK):
        os.remove(_DISK)
    subprocess.run([c1541, "-format", "speed,01", "d64", _DISK,
                    "-write", os.path.join(tmp, "big"), "big",
                    "-write", os.path.join(tmp, "one"), "one"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   check=True)
    shutil.rmtree(tmp)
    return True


_HAVE = _make_disk()
VICE_DISK = "data/_scratch_speed.d64" if _HAVE else None

CR = 0x0D


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text])
    v.write_byte(0x00C6, len(text))


def _prompt(v):
    for _ in range(40):
        v.run_for(0.25)
        rows = [r for r in v.screen_rows() if r.strip()]
        if rows and re.match(r"^8(: \S+)?>$", rows[-1].rstrip()):
            return
    raise AssertionError("no prompt:\n%s" % v.screen_text())


def _run_until_break(v, timeout=90.0):
    """Resume, and block until a breakpoint/watchpoint stops the machine.

    Keeping the monitor connection open is what makes this work: `x` resumes
    the emulator, and the monitor prompt only comes back when something stops
    it. Returns False on a wall-clock timeout."""
    v.sock.sendall(b"x\n")
    v.sock.settimeout(timeout)
    buf = b""
    deadline = time.time() + timeout
    try:
        while time.time() < deadline:
            data = v.sock.recv(4096)
            if not data:
                return False
            buf += data
            if re.search(rb"\([C8]:\$[0-9a-f]{4}\) $", buf[-12:]):
                return True
    except socket.timeout:
        pass
    return False


def _time_fload(v, name, data):
    """Seconds from RETURN to the last byte stored, and whether every byte is
    right."""
    _prompt(v)
    seed_disk_bank(v)
    last = BASE + len(data) - 1
    v.write_memory(BASE, [0x55] * len(data))
    v.write_byte(last, data[-1] ^ 0xFF)
    _type(v, "fload %s" % name)
    for _ in range(40):                  # typed, not yet entered
        v.run_for(0.05)
        if v.read_byte(0x00C6) == 0:
            break
    v._command("watch store $%04x" % last)
    _type(v, "\r")
    v._command("sw reset")
    stopped = _run_until_break(v)
    v._command("delete")                 # drop the watchpoint
    assert stopped, "fload %s never stored its last byte:\n%s" \
        % (name, v.screen_text())
    cyc = int(re.search(r"Stopwatch:\s*(\d+)", v._command("sw")).group(1))
    v.run_for(1.0)                       # let the load finish and print
    got = bytes(v.read_memory(BASE, len(data)))
    bad = sum(1 for a, b in zip(got, data) if a != b)
    return cyc / PAL_HZ, bad


def test_fload_16k_keeps_pace_with_the_epyx_cart(v):
    if not _HAVE:
        print("      (skipped: c1541 not available)")
        return
    secs, bad = _time_fload(v, "big", BIG)
    print("      16KB fload: %.2f s (Epyx cart: 9.28 s)" % secs)
    assert bad == 0, "%d of %d bytes wrong" % (bad, len(BIG))
    # ~9.0 s now. Losing the controller-tick kick is ~17 s; widening the
    # badline gate again, ~12 s.
    assert secs < 10.0, (
        "16KB took %.2f s: sectors are missing the interleave again. Check the "
        "timer kick in read_sector (src/drive1541.s) and badtab's blocked "
        "offsets (src/fastload_recv.s)" % secs)


def test_fload_setup_is_as_quick_as_the_epyx_cart(v):
    if not _HAVE:
        print("      (skipped: c1541 not available)")
        return
    secs, bad = _time_fload(v, "one", ONE)
    print("      one-sector fload: %.2f s (Epyx cart: 2.07 s)" % secs)
    assert bad == 0, "%d of %d bytes wrong" % (bad, len(ONE))
    # 2.03 s here, and steady run to run: the motor spins up from our own seek,
    # so the timeline is anchored to the command, not to wherever the disk was.
    # Without that seek it is 2.22 s; with the bootstrap but the old C send
    # loop ~2.4 s; with the whole loader M-W'd up ~3.3 s.
    assert secs < 2.13, (
        "a one-sector fload took %.2f s: the setup has regressed. See "
        "fastload_drive_install (src/fastload.c) and src/drive1541_boot.s"
        % secs)
