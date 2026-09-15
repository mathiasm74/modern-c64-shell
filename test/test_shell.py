"""The C shell (src/shell.c): a prompt, a line reader, and command dispatch.

Phase 4 boots into a C shell that prints "> ", reads a line, and reports
"command not found" for whatever was typed. These tests inject a line into
the keyboard buffer (the same path GETIN reads) and assert on the response.

Each test that types a command starts with a clear ($93) so it works from a
known screen regardless of the boot banner and prompt position.
"""

import os

CLEAR = 0x93
CR = 0x0D
DEL = 0x14


def _send(v, codes):
    """Place raw PETSCII codes in the keyboard buffer and let the shell run."""
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def test_boot_shows_prompt(v):
    # A fresh boot drops straight into the shell, which prints its prompt.
    assert "> " in v.screen_text(), "shell prompt '> ' not on screen after boot"
    assert "Command not found" not in v.screen_text(), \
        "shell reported a command before anything was typed"


def test_prompt_shows_device_number(v):
    # The prompt is prefixed with the current device number (8 at boot, no name).
    prompt = None
    for r in v.screen_rows():
        if r.strip().endswith(">"):
            prompt = r.strip()
    assert prompt is not None, "no prompt row found"
    assert prompt.startswith("8>"), \
        "prompt should start with the device number, got %r" % prompt


def test_unknown_command_reports(v):
    # "foo" + RETURN -> the shell reports it as an unknown command.
    _send(v, [CLEAR, 0x66, 0x6F, 0x6F, CR])   # f o o RETURN
    v.assert_screen_contains("Command not found: foo")


def test_empty_line_reprompts(v):
    # RETURN on an empty line just reprints the prompt; no error, no dispatch.
    before = v.screen_text().count(">")
    _send(v, [CR])
    after = v.screen_text().count(">")
    assert after >= before + 1, "empty line did not produce a fresh prompt"
    assert "Command not found" not in v.screen_text(), \
        "empty line should not be treated as a command"


def test_line_editing_backspace(v):
    # Type "az", delete the 'z', type 'b' -> the dispatched command is "ab".
    _send(v, [CLEAR, 0x61, 0x7A, DEL, 0x62, CR])   # a z <DEL> b RETURN
    v.assert_screen_contains("Command not found: ab")
    assert "Command not found: azb" not in v.screen_text(), \
        "backspace did not remove 'z' from the command line"


def test_screen_scrolls_under_shell(v):
    # A marker command, then enough commands to push it off the top. Each
    # "x<CR>" pair is one command; five fit in the 10-byte keyboard buffer.
    _send(v, [CLEAR, 0x7A, 0x7A, 0x7A, CR])        # "zzz" -> marker response
    assert "zzz" in v.screen_text(), "marker command response not shown"
    for _ in range(4):
        _send(v, [0x78, CR] * 5)                   # 5 "x" commands per batch
    assert "zzz" not in v.screen_text(), \
        "screen did not scroll the marker command off the top"
    v.assert_screen_contains("Command not found: x")   # shell still running


def test_scroll_does_not_duplicate_lines(v):
    # Issue 20 distinct one-letter commands so the screen scrolls several
    # times; each prints "Command not found: <letter>". Read top-to-bottom,
    # the visible letters must be strictly ascending -- a scroll that
    # duplicated a row (the page-boundary bug) would repeat or reorder one.
    _send(v, [CLEAR])
    seq = []
    for ch in "abcdefghijklmnopqrst":
        seq += [ord(ch), CR]
    for i in range(0, len(seq), 10):
        _send(v, seq[i:i + 10])
    seen = [r.rstrip()[-1] for r in v.screen_rows()
            if r.lstrip().startswith("Command not found:")]
    assert seen == sorted(seen) and len(seen) == len(set(seen)), \
        "scroll duplicated or reordered lines; letters seen: %r" % "".join(seen)


def test_bank_command_is_known_not_unknown(v):
    """A BANK_CMD row is a KNOWN command that may be unreachable.

    Data-driven dispatch (shell.h) lets a table row name a bank entry instead of
    a resident function, so a bank command has no resident code at all -- only
    its row. Keeping the row (rather than moving the name into the bank too) is
    what makes this distinction possible: with no One ROM answering, `ls` must
    say the bank is unavailable, NOT "Command not found", which would wrongly
    tell the user the command does not exist.

    No seed_disk_bank() here on purpose -- that is the point of the test.
    """
    _send(v, [CLEAR] + [ord(c) for c in "ls"] + [CR])
    for _ in range(10):
        v.run_for(0.5)
        if "unavailable" in v.screen_text():
            break
    txt = v.screen_text()
    assert "bank unavailable" in txt, \
        "a bank command with no bank should report it is unavailable\n%s" % txt
    assert "Command not found" not in txt, \
        "a bank command must not report as unknown -- it IS a known command\n%s" % txt


def test_command_names_live_in_the_kernal_half(v):
    """The dispatch table and its name strings must be KERNAL-side.

    Only the KERNAL half is reachable from a bank, and the files bank walks this
    table for `help` -- following each row's name pointer. Put the strings in the
    BASIC half and the bank reads its own code instead, which is the "help
    printed structured garbage" bug.

    It is worth pinning because the pressure that keeps it right can reverse: the
    table is in RODATA2 only by a deliberately unmatched `#pragma rodata-name`
    push in shell.c, and v0.2.38 moved the CODE2 blocks around it back to the
    BASIC half. One stray `pop` and this goes quietly wrong -- on hardware only,
    since a VICE bank runs from RAM where both halves are readable.
    """
    (void) = v

    labels = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "..", "build", "labels.txt")
    addr = None
    with open(labels) as f:
        for line in f:
            p = line.split()
            if len(p) >= 3 and p[2] == "._shell_commands":
                addr = int(p[1], 16) & 0xFFFF
    assert addr is not None, "_shell_commands not in build/labels.txt"
    assert addr >= 0xE000, \
        "the dispatch table is at $%04X, in the BASIC half -- a bank cannot " \
        "reach it, so `help` would read its own code" % addr

    kernal = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "..", "build", "kernal.bin"), "rb").read()
    for name in (b"devices", b"border", b"status", b"debug", b"hex"):
        assert name in kernal, \
            "the command name %r is not in the KERNAL half -- the table's " \
            "pointers would dangle into the swapped-out BASIC half" % name
