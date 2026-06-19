"""cd: change the drive's working path, and report a failed change.

cd sends "CD:<path>" to the command channel, then reads the drive's error
channel and reports any failure -- so a bad target is no longer silent. A 1541
has no CD command and answers "31, SYNTAX ERROR", which is what we can assert
under VICE; network drives (Meatloaf) navigate and only error on a missing
path (hardware-verified). A successful cd is silent. The 1541 rejects CD so
nothing is written -- read-only, tracked fixture.

cd now lives in the files overlay (it reuses the overlay's command_channel +
status read, the same path mv/rm use), so the tests seed that overlay.
"""

from lib.overlays import seed_files

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


def test_cd_reports_drive_error(v):
    # The 1541 has no CD command -> "31, SYNTAX ERROR"; cd must surface it
    # (readably: just the message, no raw ",00,00" suffix), not stay silent.
    # cd is now in the files overlay (it reuses command_channel), so seed it.
    v.run_for(0.3)
    seed_files(v)
    _type_cmd(v, "cd nowhere", clear=True)
    assert _wait(v, "SYNTAX ERROR"), \
        "cd did not report the drive error\n%s" % v.screen_text()
    assert "cd:" in v.screen_text(), \
        "cd error missing its prefix\n%s" % v.screen_text()
    assert ",00,00" not in v.screen_text(), \
        "cd error still shows the raw track/sector suffix\n%s" % v.screen_text()
    # shell survives
    _type_cmd(v, "ver", clear=True)
    assert _wait(v, "Tardis DOS v"), "shell unresponsive after cd error"


def test_cd_no_arg_usage(v):
    v.run_for(0.3)
    _type_cmd(v, "cd", clear=True)
    assert _wait(v, "usage: cd"), \
        "cd with no arg should print usage\n%s" % v.screen_text()


def _cmd_at_0340(v, n):
    return "".join(chr(b) for b in v.read_memory(0x0340, n))


def test_cd_root_builds_absolute_command(v):
    # `cd /` is absolute (from root): CMD/Meatloaf drives want "CD//", not the
    # relative "CD:/". The thunk prebuilds the command at $0340; the actual
    # root navigation is hardware-only (VICE's 1541 just SYNTAX ERRORs), so we
    # assert the bytes it builds. A leading '/' -> "cd/" + path.
    v.run_for(0.3)
    seed_files(v)
    _type_cmd(v, "cd /", clear=True)
    v.run_for(0.5)
    assert _cmd_at_0340(v, 4) == "cd//", \
        "cd / should build 'cd//', got %r" % _cmd_at_0340(v, 4)


def test_cd_absolute_subdir_command(v):
    # `cd /games` -> "cd//games" (absolute), while a relative `cd games` stays
    # "cd:games".
    v.run_for(0.3)
    seed_files(v)
    _type_cmd(v, "cd /games", clear=True)
    v.run_for(0.5)
    assert _cmd_at_0340(v, 9) == "cd//games", \
        "cd /games should build 'cd//games', got %r" % _cmd_at_0340(v, 9)
    _type_cmd(v, "cd games", clear=True)
    v.run_for(0.5)
    assert _cmd_at_0340(v, 8) == "cd:games", \
        "cd games should build 'cd:games', got %r" % _cmd_at_0340(v, 8)
