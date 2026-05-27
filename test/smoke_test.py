#!/usr/bin/env python3
"""Phase 0 smoke test.

Boot the ROM in VICE (x64sc) with the text remote monitor enabled, read
screen RAM at $0400, decode C64 screen codes, and assert that "HELLO" is
present. Exits 0 on success, nonzero on failure.

The plan calls for the text monitor over TCP for the first cut; the binary
monitor is a later optimization (see PLAN.md, Phase 2).
"""

import os
import re
import shutil
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KERNAL = os.path.join(ROOT, "build", "kernal.bin")
BASIC = os.path.join(ROOT, "build", "basic.bin")

SCREEN_RAM = 0x0400
SCREEN_COLS = 40


def find_free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def screencode_to_ascii(code):
    """Decode a C64 screen code (uppercase/graphics charset) to ASCII."""
    code &= 0x7F  # ignore the reverse-video bit
    if code == 0:
        return "@"
    if 1 <= code <= 26:
        return chr(64 + code)  # 1->A .. 26->Z
    if 27 <= code <= 31:
        return "[\\]^_"[code - 27]
    if 32 <= code <= 63:
        return chr(code)  # space, punctuation, digits map 1:1
    return "."


def connect(port, timeout=20.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=1.0)
            sock.settimeout(1.0)
            return sock
        except OSError as exc:
            last = exc
            time.sleep(0.25)
    raise RuntimeError("could not reach VICE monitor on port %d: %s" % (port, last))


def drain(sock, settle=0.5):
    """Read from the monitor until it goes quiet for `settle` seconds."""
    sock.settimeout(settle)
    chunks = []
    while True:
        try:
            data = sock.recv(4096)
            if not data:
                break
            chunks.append(data)
        except socket.timeout:
            break
    return b"".join(chunks).decode("latin-1", "replace")


def read_screen(sock):
    """Return the first screen line ($0400-$0427) as a list of byte values."""
    start, end = SCREEN_RAM, SCREEN_RAM + SCREEN_COLS - 1
    sock.sendall(("m %04x %04x\n" % (start, end)).encode("ascii"))
    text = drain(sock)
    values = []
    # Monitor memory dumps look like: ">C:0400  08 05 0c 0c 0f 20 ...   :....."
    for line in text.splitlines():
        m = re.search(r"[Cc]:[0-9a-fA-F]{4}\s+((?:[0-9a-fA-F]{2}[ \t]+)+)", line)
        if m:
            values.extend(int(b, 16) for b in m.group(1).split())
    return values


def read_byte(sock, addr):
    sock.sendall(("m %04x %04x\n" % (addr, addr)).encode("ascii"))
    for line in drain(sock).splitlines():
        m = re.search(r"[Cc]:[0-9a-fA-F]{4}\s+([0-9a-fA-F]{2})", line)
        if m:
            return int(m.group(1), 16)
    return None


def main():
    for path in (KERNAL, BASIC):
        if not os.path.exists(path):
            print("FAIL: missing %s (run `make` first)" % path, file=sys.stderr)
            return 1

    x64sc = shutil.which("x64sc")
    if not x64sc:
        print("FAIL: x64sc not found on PATH", file=sys.stderr)
        return 1

    port = find_free_port()
    cmd = [
        x64sc,
        "-default",                 # ignore the user's saved VICE config
        "-warp",                    # boot as fast as possible
        "+sound",                   # no audio device in headless runs
        "-jamaction", "1",          # on CPU jam: continue (never block on a dialog)
        "-remotemonitor",
        "-remotemonitoraddress", "ip4://127.0.0.1:%d" % port,
        "-kernal", KERNAL,
        "-basic", BASIC,
    ]
    print("launching:", " ".join(cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    sock = None
    try:
        # Let the emulator come up; the connect() retry loop tolerates a slow
        # start. By the time we connect, reset has long since painted HELLO.
        time.sleep(0.5)
        sock = connect(port)
        drain(sock)  # consume the monitor banner / prompt

        screen = read_screen(sock)
        decoded = "".join(screencode_to_ascii(b) for b in screen)
        print("screen $0400: %r" % decoded)

        # The VIC-II must actually be displaying $0400, or the screen is blank
        # regardless of what's in RAM (DEN off / wrong screen pointer).
        ctrl1 = read_byte(sock, 0xD011)
        memptr = read_byte(sock, 0xD018)
        display_on = ctrl1 is not None and (ctrl1 & 0x10) != 0
        screen_at_0400 = memptr is not None and (memptr & 0xF0) == 0x10
        print("VIC $D011=%s $D018=%s -> display %s, screen base %s" % (
            "$%02X" % ctrl1 if ctrl1 is not None else "?",
            "$%02X" % memptr if memptr is not None else "?",
            "ON" if display_on else "OFF",
            "$0400" if screen_at_0400 else "elsewhere"))

        ok = True
        if "HELLO" not in decoded:
            print("FAIL: HELLO not in screen RAM; got %r" % decoded, file=sys.stderr)
            print("raw bytes: %r" % screen, file=sys.stderr)
            ok = False
        if not display_on:
            print("FAIL: VIC display disabled (DEN clear) - screen would be blank",
                  file=sys.stderr)
            ok = False
        if not screen_at_0400:
            print("FAIL: VIC screen base is not $0400 ($D018=%r)" % memptr,
                  file=sys.stderr)
            ok = False

        if ok:
            print("PASS: HELLO is on a visible screen")
            return 0
        return 1
    finally:
        if sock is not None:
            try:
                sock.sendall(b"quit\n")  # ask VICE to exit
            except OSError:
                pass
            sock.close()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
