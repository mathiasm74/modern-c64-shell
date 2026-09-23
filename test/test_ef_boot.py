"""Tardis itself, built for EasyFlash (PLAN.md section 7, phase 2).

The shell, the parser and every command are the SAME sources as the One ROM
build -- only the platform layer (src/ef/platform.s) and the linker config
differ. This checks the port boots on a STOCK machine with the cart attached,
draws its banner, and runs commands.

All five banks are in the cart (EF banks 1-5); test_ef_banks.py drives the ones
that need a drive. This module covers boot and the resident shell.
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

_HERE = os.path.dirname(os.path.abspath(__file__))
_CRT = os.path.join(_HERE, "..", "build", "ef", "tardis.crt")
_STOCK_K = os.path.join(_HERE, "..", "stock-roms", "kernal.901227-03.bin")
_STOCK_B = os.path.join(_HERE, "..", "stock-roms", "basic.901226-01.bin")
_HAVE = (os.path.exists(_CRT) and os.path.exists(_STOCK_K)
         and os.path.exists(_STOCK_B))


def _vice():
    sys.path.insert(0, os.path.join(_HERE, "lib"))
    from vice import Vice
    return Vice(kernal=_STOCK_K, basic=_STOCK_B,
                extra_args=["-cartcrt", _CRT, "+easyflashjumper"])


def _boot(sv):
    """Run until the shell's prompt appears; return the screen."""
    got = ""
    for _ in range(40):
        sv.run_for(0.25)
        got = sv.screen_text()
        # "8>" bare, or "8: 1541>" once the boot-time identify has named the
        # drive -- which happens when a disk is attached.
        if "8>" in got or "8: " in got:
            return got
    raise AssertionError("the EF build never reached its prompt:\n%s" % got)


def test_ef_build_boots_to_the_tardis_prompt(v):
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt or no stock ROMs)")
        return
    with _vice() as sv:
        got = _boot(sv)
        # The banner proves main()'s environment is real, not just that some
        # code ran: it is printed through CHROUT, which means CINT ran, our
        # chrout_impl is on $0326, and the stock $FFD2 routes through it.
        assert "Tardis DOS" in got, "banner missing:\n%s" % got
        assert "power shell" in got, "banner incomplete:\n%s" % got
        assert "Free ROM bytes" in got, "free-bytes line missing:\n%s" % got


def test_ef_build_runs_a_resident_command(v):
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt or no stock ROMs)")
        return
    with _vice() as sv:
        _boot(sv)
        # `ver` is resident, so this exercises the whole loop -- our keyboard
        # scan on $0314 (which must leave through $EA81, not RTI: the stock
        # $FF48 already pushed the registers), readline, dispatch, chrout.
        _type(sv, "ver\r")
        got = sv.screen_text()
        assert "Tardis DOS v" in got, "ver produced nothing:\n%s" % got


def _type(sv, text):
    """Type a line, nine characters at a time (the keyboard buffer's depth)."""
    for chunk in [text[i:i + 9] for i in range(0, len(text), 9)]:
        sv.inject_keys(chunk)
        for _ in range(40):
            sv.run_for(0.1)
            if sv.read_byte(0xC6) == 0:
                break
    sv.run_for(0.8)


def test_ef_boot_applies_the_tardis_screen_not_the_stock_one(v):
    """ef_cold calls stock CINT, which leaves a stock-looking machine behind.

    Two things have to be taken back afterwards, and the second is not
    cosmetic: CINT sets $D018 = $15, the UPPERCASE/graphics charset, and
    Tardis runs the LOWERCASE/text one -- that is what makes its encoding
    ASCII-consistent ('a' -> screen code $01, via pet2scr). Left alone, the
    shell comes up in the wrong font and every lowercase letter it prints is a
    graphic. (Reported from a live session: "the screen is blue, and the font
    is uppercase and symbols".)
    """
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt or no stock ROMs)")
        return
    with _vice() as sv:
        _boot(sv)
        # $D018 bit 0 is unused and reads back set, so mask it off.
        assert sv.read_byte(0xD018) & 0xFE == 0x16, \
            "charset/screen base is $%02X, not $16 (lowercase @ $1800)" \
            % sv.read_byte(0xD018)
        assert sv.read_byte(0xD020) & 0x0F == 0x0A, "border is not light red"
        assert sv.read_byte(0xD021) & 0x0F == 0x02, "background is not dark red"
        assert sv.read_byte(0x0286) == 0x01, "text colour is not white"
        assert sv.read_byte(0xD800) & 0x0F == 0x01, \
            "colour RAM still holds CINT's fill, so drawn text is invisible"
        # And prove the encoding end to end: the banner's "Tardis" must be
        # stored as T=$54 then lowercase a,r,d,i,s = $01,$12,$04,$09,$13.
        row2 = bytes(sv.read_memory(0x0400 + 40 * 2, 40))
        assert bytes([0x54, 0x01, 0x12, 0x04, 0x09, 0x13]) in row2, \
            "banner is not in the lowercase charset's codes: %s" % row2.hex(' ')


def test_ef_util_bank_commands_run(v):
    """The util bank ports to EF unchanged except for where its RAM lives.

    This is the whole bank path end to end: bank_call writes $DE00, ROML stays
    put because every bank repeats it, the "bnk" magic checks out, and the
    $DF00 stub JSRs the right entry. `about` is entry 1 and pure assembly;
    the colour commands are entries 3-5 and go through bank_init, so they also
    prove the cc65 runtime comes up in the relocated window.
    """
    (void) = v
    if not _HAVE:
        print("      (skipped: no tardis.crt or no stock ROMs)")
        return
    with _vice() as sv:
        _boot(sv)
        _type(sv, "text 5\r")
        assert sv.read_byte(0x0286) == 0x05, \
            "text: $0286 = $%02X" % sv.read_byte(0x0286)
        _type(sv, "border 3\r")
        assert sv.read_byte(0xD020) & 0x0F == 0x03, \
            "border: $D020 = $%02X" % sv.read_byte(0xD020)
        _type(sv, "bg 6\r")
        assert sv.read_byte(0xD021) & 0x0F == 0x06, \
            "bg: $D021 = $%02X" % sv.read_byte(0xD021)
        # Entry 1, the assembly path, which skips bank_init entirely.
        _type(sv, "clear\r")
        _type(sv, "about\r")
        assert "TARDIS DOS" in sv.screen_text(), \
            "about did not run:\n%s" % sv.screen_text()


def test_ef_bank_ram_window_is_readable_memory(v):
    """The bank's DATA/BSS/C stack must NOT sit in $8000-$9FFF on this target.

    That is ROML here: a write lands in the RAM underneath and the read comes
    back from flash, so the window is write-only and every C bank entry
    silently does nothing (the colour commands returned without setting a
    single register). The One ROM build's window at $9D00 is exactly there,
    which is why the EF configs are separate files.
    """
    (void) = v
    import glob
    import re
    cfgs = glob.glob(os.path.join(_HERE, "..", "build", "ef", "cfg", "*_bank.cfg"))
    assert cfgs, "no generated EF bank configs found -- run `make ef`"
    for path in cfgs:
        for line in open(path):
            m = re.match(r"\s*(DATARUN|BANKBSS|BANKRAM)\s*:.*start\s*=\s*\$([0-9A-Fa-f]+)",
                         line)
            if m:
                start = int(m.group(2), 16)
                assert not (0x8000 <= start < 0xA000), \
                    "%s: %s starts at $%04X, inside ROML -- reads come from " \
                    "flash, so the bank's state would be write-only" % (
                        os.path.basename(path), m.group(1), start)


def test_every_crt_bank_carries_an_identical_roml(v):
    """$DE00 banks BOTH windows, so ROML is only "always mapped" if it repeats.

    bank_call runs from ROML and writes $DE00 mid-routine; if the incoming bank
    held a different ROML, the CPU's next fetch would come from a different
    image at the same address. This is the invariant that makes it safe.
    """
    (void) = v
    if not os.path.exists(_CRT):
        print("      (skipped: no tardis.crt)")
        return
    data = open(_CRT, "rb").read()
    hdr = struct.unpack(">I", data[0x10:0x14])[0]
    off, roml = hdr, {}
    while off < len(data):
        assert data[off:off + 4] == b"CHIP", "bad chip packet at $%X" % off
        plen, bank, load = (struct.unpack(">I", data[off + 4:off + 8])[0],
                            struct.unpack(">H", data[off + 10:off + 12])[0],
                            struct.unpack(">H", data[off + 12:off + 14])[0])
        size = struct.unpack(">H", data[off + 14:off + 16])[0]
        if load == 0x8000:
            roml[bank] = data[off + 16:off + 16 + size]
        off += plen
    assert len(roml) >= 2, "expected several banks, got %d" % len(roml)
    first = roml[0]
    for bank, image in sorted(roml.items()):
        assert image == first, \
            "bank %d's ROML differs from bank 0's -- bank_call would be " \
            "switched out from under itself" % bank


def test_ef_bank_images_match_the_onerom_banks(v):
    """The EF banks are RELINKED from the same C objects as the One ROM banks,
    so their string data must be identical. A mismatch means one set was built
    from newer objects than the other.

    Regression for a make bug that produced exactly that: FILES/HEX/EDIT_BANK_OBJ
    were defined BELOW the EF link rules, and make expands prerequisites as a
    rule is read -- so those three EF banks depended on their crt0 and cfg
    alone. Editing edit.c relinked the One ROM bank and left the EF one stale,
    and `make ef` packed the stale bank into the .crt. The banner showed the new
    version while the bank ran old code, which reads like a source/hardware
    contradiction rather than a build fault.
    """
    (void) = v
    banks = ["disk_bank", "util_bank", "files_bank", "edit_bank", "hex_bank"]
    base = os.path.join(_HERE, "..", "build", "banks")
    efd = os.path.join(_HERE, "..", "build", "ef", "banks")

    def strings(path, least=6):
        out, cur = set(), bytearray()
        for b in open(path, "rb").read():
            if 32 <= b < 127:
                cur.append(b)
                continue
            if len(cur) >= least:
                out.add(bytes(cur))
            cur = bytearray()
        if len(cur) >= least:
            out.add(bytes(cur))
        return out

    checked = 0
    for name in banks:
        a = os.path.join(base, name + ".bin")
        b = os.path.join(efd, name + ".bin")
        if not (os.path.exists(a) and os.path.exists(b)):
            continue
        only_onerom = strings(a) - strings(b)
        only_ef = strings(b) - strings(a)
        assert not (only_onerom or only_ef), (
            "%s differs between the targets -- one is stale.\n"
            "  only in the One ROM bank: %s\n"
            "  only in the EF bank:      %s" % (name, sorted(only_onerom)[:6],
                                                sorted(only_ef)[:6]))
        checked += 1
    assert checked >= 4, "expected to compare the banks, compared %d" % checked
