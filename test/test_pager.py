"""cat dumps a file to the screen; less pages it.

Both read the SEQ file "doc" on the test disk -- 30 lines, "l00".."l29".
cat is read-only, so this mounts the tracked fixture directly.
"""

VICE_DISK = "data/test.d64"

CR = 0x0D
CLEAR = 0x93
SPACE = 0x20


def _ch(s):
    return [ord(c) for c in s]


def _send(v, codes):
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def _wait(v, needle, tries=20, chunk=0.6):
    for _ in range(tries):
        v.run_for(chunk)
        if needle in v.screen_text():
            return True
    return False


def test_cat_dumps_file(v):
    v.run_for(0.3)
    _send(v, [CLEAR] + _ch("cat doc") + [CR])
    assert _wait(v, "l29"), "cat did not reach the last line"
    txt = v.screen_text()
    assert "l28" in txt and "l29" in txt, "cat tail missing"


def test_less_pages_file(v):
    v.run_for(0.3)
    _send(v, [CLEAR] + _ch("less doc") + [CR])
    assert _wait(v, "more"), "less did not pause with a more prompt"
    txt = v.screen_text()
    assert "l00" in txt, "less page 1 is missing the first line"
    assert "l29" not in txt, "less dumped the whole file without paging"
    _send(v, [SPACE])                      # advance to the next page
    assert _wait(v, "l29"), "less did not page to the rest of the file"
