#!/usr/bin/env python3
"""Pack 8KB images into an EasyFlash .crt (PLAN.md section 7).

    python3 tools/make_ef_crt.py out.crt bank:chip=file ...
        e.g.  0:l=build/ef/roml0.bin  0:h=build/ef/romh0.bin  1:h=build/ef/romh1.bin

An EF bank is 16KB: an 8KB ROML chip and an 8KB ROMH chip, carried as separate
CHIP packets. The load address in the packet is what tells the emulator which is
which -- $8000 for ROML, $A000 for ROMH -- even though bank 0's ROMH is actually
seen at $E000 in Ultimax, which is where the machine starts.

Header EXROM/GAME are LINE states (0 = pulled low = active). EasyFlash boots in
Ultimax, which is /GAME low and /EXROM high, so GAME=0 and EXROM=1.
"""
import os
import struct, sys

CRT_MAGIC = b"C64 CARTRIDGE   "
CRT_TYPE_EASYFLASH = 32


def chip_packet(bank, load_addr, data):
    assert len(data) == 0x2000, "each EF chip image must be exactly 8KB"
    body = struct.pack(">HHHH", 2, bank, load_addr, len(data)) + data
    return b"CHIP" + struct.pack(">I", 16 + len(data)) + body


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    out, specs = argv[1], argv[2:]

    name = b"TARDIS EF SPIKE"
    header = (CRT_MAGIC
              + struct.pack(">I", 0x40)          # header length
              + struct.pack(">H", 0x0100)        # version 1.0
              + struct.pack(">H", CRT_TYPE_EASYFLASH)
              + bytes([1])                       # EXROM high
              + bytes([0])                       # GAME low  -> boots in Ultimax
              + bytes(6)                         # reserved
              + name.ljust(32, b"\0"))
    assert len(header) == 0x40

    packets = []
    for spec in specs:
        where, path = spec.split("=", 1)
        bank, chip = where.split(":")
        addr = 0x8000 if chip.lower() == "l" else 0xA000
        packets.append(chip_packet(int(bank), addr, open(path, "rb").read()))

    # Write via a temp file and rename. A generator that opens its output and
    # then fails leaves an EMPTY file with a fresh mtime, which make happily
    # treats as up to date -- and every test afterwards runs a zero-byte
    # cartridge while the build says "nothing to be done". That cost real
    # debugging time; os.replace is atomic, so the output either appears whole
    # or not at all.
    tmp = out + ".tmp"
    with open(tmp, "wb") as f:
        f.write(header + b"".join(packets))
    os.replace(tmp, out)
    print("  %s : %d bytes, %d chip packet(s)" %
          (out, 0x40 + sum(len(p) for p in packets), len(packets)))


if __name__ == "__main__":
    main(sys.argv)
