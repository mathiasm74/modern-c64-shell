"""The Phase 1 startup banner is drawn on a visible screen."""


def test_banner_text(v):
    v.assert_screen_contains("C64 SHELL ROM")
    v.assert_screen_contains("READY")


def test_display_enabled(v):
    v.assert_display_enabled()


def test_screen_base_is_0400(v):
    memptr = v.read_byte(0xD018)
    assert memptr is not None and (memptr & 0xF0) == 0x10, \
        "VIC screen base is not $0400 ($D018=%s)" % (
            "$%02X" % memptr if memptr is not None else "?")
