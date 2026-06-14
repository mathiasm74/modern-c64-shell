"""status: read and print the drive's command/error channel (15).

The classic "blinking red light" check. After a successful op the channel
holds "00, OK,00,00"; after a failure it holds the DOS error, e.g.
"62,FILE NOT FOUND,00,00". status opens channel 15 with no filename and
streams the message. All read-only, so this runs on the tracked fixture.
"""

from lib.overlays import seed_dir

VICE_DISK = "data/test.d64"

CR = 0x0D
CLEAR = 0x93


def _ch(s):
    return [ord(c) for c in s]


def _type_cmd(v, text, clear=False):
    codes = ([CLEAR] if clear else []) + _ch(text) + [CR]
    while codes:
        chunk, codes = codes[:8], codes[8:]
        v.write_memory(0x0277, chunk)
        v.write_byte(0x00C6, len(chunk))
        v.run_for(0.3)


def _wait(v, needle, tries=14, chunk=0.5):
    for _ in range(tries):
        v.run_for(chunk)
        if needle in v.screen_text():
            return True
    return False


def test_status_ok_after_successful_op(v):
    # A clean directory read leaves the error channel at "00, OK,00,00".
    v.run_for(0.3)
    seed_dir(v)
    _type_cmd(v, "dir", clear=True)
    assert _wait(v, "BLOCKS FREE"), "dir did not finish\n%s" % v.screen_text()
    _type_cmd(v, "status", clear=True)
    assert _wait(v, "OK"), "status not OK after a good op\n%s" % v.screen_text()
    assert "00" in v.screen_text(), \
        "status missing the 00 code\n%s" % v.screen_text()


def test_status_reports_error(v):
    # Opening a missing file leaves a non-OK DOS error on the channel.
    v.run_for(0.3)
    _type_cmd(v, "load zznope", clear=True)
    _wait(v, "not found")                       # our load's own message
    _type_cmd(v, "status", clear=True)
    txt = v.screen_text()
    assert "FILE NOT FOUND" in txt or "62" in txt, \
        "status did not report the failed open\n%s" % txt
