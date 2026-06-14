"""status: read + reformat the drive's command/error channel (15).

The classic "blinking red light" check. The raw DOS reply is
"code,message,track,sector"; status reformats it to "code message" (dropping
the redundant ,00,00 track/sector unless a real disk error sets them) and
always ends on a fresh line. status lives in the files overlay (the buffering
+ comma parse cost too much resident ROM), so seed it before each call.

The Meatloaf-specific bug that motivated the rewrite -- the drive ends the
status on its last data byte with no trailing CR, so the old code never
emitted a newline and a stray CR surfaced on the next call -- can't be
reproduced under VICE's 1541 (which sends the CR), but the always-one-newline
contract and the readable reformat are checked here; the no-CR path is
hardware-verified. All read-only, so this runs on the tracked fixture.
"""

from lib.overlays import seed_files, seed_dir

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


def test_status_ok_is_readable(v):
    # A clean directory read leaves the channel at "00, OK,00,00"; status
    # reformats that to "00 OK" and drops the redundant track/sector.
    v.run_for(0.3)
    seed_dir(v)
    _type_cmd(v, "dir", clear=True)
    assert _wait(v, "BLOCKS FREE"), "dir did not finish\n%s" % v.screen_text()
    seed_files(v)                               # status is in the files overlay
    _type_cmd(v, "status", clear=True)
    assert _wait(v, "00 OK"), \
        "status not reformatted to '00 OK'\n%s" % v.screen_text()
    assert ",00,00" not in v.screen_text(), \
        "status still shows the raw track/sector suffix\n%s" % v.screen_text()


def test_status_reports_error(v):
    # Opening a missing file leaves "62,FILE NOT FOUND,00,00" -> "62 FILE NOT
    # FOUND".
    v.run_for(0.3)
    _type_cmd(v, "load zznope", clear=True)
    _wait(v, "not found")                       # our load's own message
    seed_files(v)
    _type_cmd(v, "status", clear=True)
    txt = v.screen_text()
    assert "FILE NOT FOUND" in txt or "62" in txt, \
        "status did not report the failed open\n%s" % txt


def test_status_ends_on_fresh_line(v):
    # The prompt must land on the line AFTER the status, not appended to it.
    v.run_for(0.3)
    seed_files(v)
    _type_cmd(v, "status", clear=True)
    assert _wait(v, "OK") or "1541" in v.screen_text(), \
        "no status line on screen\n%s" % v.screen_text()
    v.run_for(0.4)                              # let the prompt redraw
    rows = v.screen_rows()
    marks = [i for i, r in enumerate(rows)
             if (" OK" in r or "1541" in r or "FOUND" in r)]
    assert marks, "could not find the status line\n%s" % v.screen_text()
    status_row = max(marks)
    cursor_row = v.read_byte(0x00D6)            # TBLX = cursor row
    assert cursor_row > status_row, \
        "prompt did not advance past the status line (missing newline)\n%s" \
        % v.screen_text()
