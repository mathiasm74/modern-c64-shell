"""The Phase 1 startup banner is drawn on a visible screen."""


def test_banner_text(v):
    v.assert_screen_contains("C64 Shell ROM")
    v.assert_screen_contains("Ready")


def test_rom_free_line(v):
    # The boot screen shows the per-ROM free bytes; tools/patch_freemem.py
    # fills the "----" placeholders post-link, so seeing digits (and no dashes)
    # in the line proves the patch ran. The exact numbers are build-specific.
    txt = v.screen_text()
    line = next((r for r in txt.split("\n") if "rom free" in r), None)
    assert line is not None, "boot screen has no 'rom free' line\n%s" % txt
    assert "basic" in line and "kernal" in line, "rom free line malformed: %r" % line
    assert "----" not in line, "patch_freemem did not fill the placeholders: %r" % line
    assert any(c.isdigit() for c in line), "rom free line has no numbers: %r" % line


def test_display_enabled(v):
    v.assert_display_enabled()


def test_screen_base_is_0400(v):
    memptr = v.read_byte(0xD018)
    assert memptr is not None and (memptr & 0xF0) == 0x10, \
        "VIC screen base is not $0400 ($D018=%s)" % (
            "$%02X" % memptr if memptr is not None else "?")
