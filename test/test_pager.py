"""cat dumps a file to the screen; less pages it.

cat/less live in the multi-page "files" tardis overlay (src/overlays/files.c,
fetched to $8800 on hardware). VICE has no One ROM, so -- like test_edit --
these tests PRE-SEED the overlay: seed_files writes the image to $8800 and the
resident thunk validates it by the magic in the header.

Both commands read the SEQ file "doc" on the test disk -- 30 lines, "l00".."l29".
"""

from lib.overlays import seed_files

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
    seed_files(v)
    _send(v, [CLEAR] + _ch("cat doc") + [CR])
    assert _wait(v, "l29"), "cat did not reach the last line"
    txt = v.screen_text()
    assert "l28" in txt and "l29" in txt, "cat tail missing"


def test_cat_leaves_prompt_on_fresh_line(v):
    # readme has no trailing newline; cat must still drop the prompt onto a
    # fresh line rather than append it to the file's last line.
    v.run_for(0.3)
    seed_files(v)
    v.write_memory(0x0277, [CLEAR] + _ch("cat read"))   # split: 10-byte buffer
    v.write_byte(0x00C6, 9)
    v.run_for(0.3)
    v.write_memory(0x0277, _ch("me") + [CR])
    v.write_byte(0x00C6, 3)
    assert _wait(v, "DISK"), "cat readme did not show the file"
    disk_row = next(r for r in v.screen_rows() if "DISK" in r)
    assert disk_row.rstrip().endswith("DISK"), \
        "prompt was appended to the file's last line: %r" % disk_row.rstrip()


def test_less_pages_file(v):
    v.run_for(0.3)
    seed_files(v)
    _send(v, [CLEAR] + _ch("less doc") + [CR])
    assert _wait(v, "more"), "less did not pause with a more prompt"
    txt = v.screen_text()
    assert "l00" in txt, "less page 1 is missing the first line"
    assert "l29" not in txt, "less dumped the whole file without paging"
    _send(v, [SPACE])                      # advance to the next page
    assert _wait(v, "l29"), "less did not page to the rest of the file"
