"""VICE test harness for the C64 shell ROM.

A thin wrapper around x64sc and its text remote monitor: launch the emulator
with our ROM, read and write memory, decode the screen, inject keystrokes,
read CPU registers, and assert on machine state. Designed to be used as a
context manager:

    from lib.vice import Vice
    with Vice() as v:
        v.assert_screen_contains("READY")

Environment variables:
    VICE_VERBOSE=1    show the launch command, monitor traffic, and VICE output
    VICE_HEADLESS=0   launch the GUI window instead of headless (-console)
"""

import os
import re
import shutil
import socket
import subprocess
import time

_THIS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(_THIS))          # test/lib -> repo root
DEFAULT_KERNAL = os.path.join(ROOT, "build", "kernal.bin")
DEFAULT_BASIC = os.path.join(ROOT, "build", "basic.bin")

SCREEN_RAM = 0x0400
SCREEN_COLS = 40
SCREEN_ROWS = 25
SCREEN_CELLS = SCREEN_COLS * SCREEN_ROWS

KBD_BUFFER = 0x0277      # keyboard buffer, $0277-$0280 (10 bytes)
KBD_COUNT = 0x00C6       # number of characters waiting in the buffer
KBD_MAX = 10

VERBOSE = os.environ.get("VICE_VERBOSE") == "1"
HEADLESS = os.environ.get("VICE_HEADLESS", "1") != "0"   # headless by default


class ViceError(Exception):
    """Harness/setup failure (as opposed to a test assertion failure)."""


def screencode_to_ascii(code):
    """Decode a C64 screen code (lowercase/text charset) to ASCII.

    The ROM boots in the lowercase charset with an ASCII-consistent encoding
    (see src/screen.s pet2scr): lowercase letters sit at screen codes $01-$1A
    and uppercase at $41-$5A.
    """
    code &= 0x7F  # ignore the reverse-video bit
    if code == 0:
        return "@"
    if 1 <= code <= 26:
        return chr(96 + code)             # 1->a .. 26->z
    if 27 <= code <= 31:
        return "[\\]^_"[code - 27]
    if 32 <= code <= 63:
        return chr(code)                  # space, punctuation, digits map 1:1
    if 65 <= code <= 90:
        return chr(code)                  # 65->A .. 90->Z (uppercase glyphs)
    return "."


def ascii_to_petscii(ch):
    """Map an ASCII character to the code the keyboard would deliver.

    The encoding is ASCII-consistent, so this is the identity for the printable
    range; only RETURN needs translating.
    """
    if ch == "\n":
        return 0x0D                       # RETURN
    return ord(ch)


class Vice:
    def __init__(self, kernal=DEFAULT_KERNAL, basic=DEFAULT_BASIC,
                 headless=None, verbose=None):
        self.kernal = kernal
        self.basic = basic
        self.headless = HEADLESS if headless is None else headless
        self.verbose = VERBOSE if verbose is None else verbose
        self.proc = None
        self.sock = None
        self.port = None

    # -- lifecycle --------------------------------------------------------
    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *exc):
        self.stop()
        return False

    def start(self):
        for path in (self.kernal, self.basic):
            if not os.path.exists(path):
                raise ViceError("missing ROM %s (run `make` first)" % path)
        x64sc = shutil.which("x64sc")
        if not x64sc:
            raise ViceError("x64sc not found on PATH")

        self.port = _free_port()
        cmd = [x64sc]
        if self.headless:
            cmd.append("-console")        # run without opening the GUI window
        cmd += [
            "-default",                   # ignore the user's saved VICE config
            "-warp",                      # boot as fast as possible
            "+sound",                     # no audio device needed
            "-jamaction", "1",            # on CPU jam: continue, never block
            "-remotemonitor",
            "-remotemonitoraddress", "ip4://127.0.0.1:%d" % self.port,
            "-kernal", self.kernal,
            "-basic", self.basic,
        ]
        self._log("launch: %s" % " ".join(cmd))
        out = None if self.verbose else subprocess.DEVNULL
        self.proc = subprocess.Popen(cmd, stdout=out, stderr=out)
        time.sleep(0.4)
        self.sock = self._connect()
        self._drain()                     # consume the monitor banner

    def stop(self):
        if self.sock is not None:
            try:
                self.sock.sendall(b"quit\n")
            except OSError:
                pass
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None

    def run_for(self, seconds=0.2):
        """Let the CPU run for `seconds`, then halt again for inspection.

        Connecting to the monitor halts the CPU; disconnecting resumes it. So
        to observe the running machine react to injected input we drop the
        connection, wait, then reconnect (which halts it once more).
        """
        self.sock.close()
        time.sleep(seconds)
        self.sock = self._connect()
        self._drain()

    # -- monitor plumbing -------------------------------------------------
    def _connect(self, timeout=20.0):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            try:
                s = socket.create_connection(("127.0.0.1", self.port), timeout=1.0)
                s.settimeout(1.0)
                return s
            except OSError as exc:
                last = exc
                time.sleep(0.25)
        raise ViceError("could not reach VICE monitor on %d: %s" % (self.port, last))

    def _drain(self, settle=0.12):
        """Read all monitor output until the socket is quiet for `settle`.

        Draining everything keeps request/response in lockstep (no leftover
        bytes to desync the next read). Monitor responses arrive as a single
        fast burst over the loopback, so a short quiet gap means "done".
        """
        self.sock.settimeout(settle)
        chunks = []
        while True:
            try:
                data = self.sock.recv(4096)
                if not data:
                    break
                chunks.append(data)
            except socket.timeout:
                break
        return b"".join(chunks).decode("latin-1", "replace")

    def _command(self, cmd):
        self._log(">>> %s" % cmd)
        self.sock.sendall((cmd + "\n").encode("ascii"))
        out = self._drain()
        if self.verbose and out.strip():
            self._log(out.strip())
        return out

    def _log(self, msg):
        if self.verbose:
            print("[vice] %s" % msg)

    # -- memory -----------------------------------------------------------
    def read_memory(self, addr, count):
        """Read `count` bytes starting at `addr`; returns a list of ints."""
        text = self._command("m %04x %04x" % (addr, addr + count - 1))
        vals = []
        for line in text.splitlines():
            m = re.search(r"[Cc]:[0-9a-fA-F]{4}\s+((?:[0-9a-fA-F]{2}[ \t]+)+)", line)
            if m:
                vals.extend(int(b, 16) for b in m.group(1).split())
        return vals[:count]

    def read_byte(self, addr):
        vals = self.read_memory(addr, 1)
        return vals[0] if vals else None

    def write_memory(self, addr, data):
        """Write a sequence of byte values starting at `addr`."""
        hexbytes = " ".join("%02x" % (b & 0xFF) for b in data)
        self._command("> %04x %s" % (addr, hexbytes))

    def write_byte(self, addr, value):
        self.write_memory(addr, [value])

    # -- screen -----------------------------------------------------------
    def screen_cells(self):
        return self.read_memory(SCREEN_RAM, SCREEN_CELLS)

    def screen_rows(self):
        cells = self.screen_cells()
        rows = []
        for r in range(SCREEN_ROWS):
            chunk = cells[r * SCREEN_COLS:(r + 1) * SCREEN_COLS]
            rows.append("".join(screencode_to_ascii(b) for b in chunk))
        return rows

    def screen_text(self):
        return "\n".join(self.screen_rows())

    # -- cpu --------------------------------------------------------------
    def registers(self):
        """Parse the monitor `r` output into {pc, a, x, y, sp}."""
        text = self._command("r")
        for line in text.splitlines():
            m = re.search(
                r"[.;]([0-9a-fA-F]{4})\s+([0-9a-fA-F]{2})\s+([0-9a-fA-F]{2})"
                r"\s+([0-9a-fA-F]{2})\s+([0-9a-fA-F]{2})", line)
            if m:
                return {"pc": int(m.group(1), 16), "a": int(m.group(2), 16),
                        "x": int(m.group(3), 16), "y": int(m.group(4), 16),
                        "sp": int(m.group(5), 16)}
        return {}

    def pc(self):
        return self.registers().get("pc")

    # -- keyboard ---------------------------------------------------------
    def inject_keys(self, text):
        """Place up to 10 characters into the C64 keyboard buffer."""
        codes = [ascii_to_petscii(c) for c in text]
        if len(codes) > KBD_MAX:
            raise ViceError("keyboard buffer holds at most %d chars" % KBD_MAX)
        self.write_memory(KBD_BUFFER, codes)
        self.write_byte(KBD_COUNT, len(codes))

    # -- screenshot (best effort; only works with a real video device) ----
    def screenshot(self, path):
        self._command('screenshot "%s"' % path)
        return os.path.exists(path)

    # -- assertions -------------------------------------------------------
    def assert_screen_contains(self, text):
        screen = self.screen_text()
        if text not in screen:
            raise AssertionError(
                "screen does not contain %r\n--- screen ---\n%s"
                % (text, _visible(screen)))

    def assert_memory_equals(self, addr, expected):
        expected = list(expected)
        actual = self.read_memory(addr, len(expected))
        if actual != expected:
            raise AssertionError(
                "memory at $%04X: expected %s, got %s"
                % (addr, _hexlist(expected), _hexlist(actual)))

    def assert_pc_at(self, addr):
        got = self.pc()
        if got != addr:
            raise AssertionError(
                "PC expected $%04X, got %s"
                % (addr, "$%04X" % got if got is not None else "?"))

    def assert_display_enabled(self):
        ctrl1 = self.read_byte(0xD011)
        if ctrl1 is None or not (ctrl1 & 0x10):
            raise AssertionError(
                "VIC display disabled ($D011=%s)"
                % ("$%02X" % ctrl1 if ctrl1 is not None else "?"))


def _free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _hexlist(vals):
    return "[" + " ".join("$%02X" % v for v in vals) + "]"


def _visible(text):
    out = []
    for i, row in enumerate(text.split("\n")):
        if row.strip():
            out.append("%2d: %s" % (i, row.rstrip()))
    return "\n".join(out)
