"""The C shell (src/shell.c): a prompt, a line reader, and command dispatch.

Phase 4 boots into a C shell that prints "> ", reads a line, and reports
"command not found" for whatever was typed. These tests inject a line into
the keyboard buffer (the same path GETIN reads) and assert on the response.

Each test that types a command starts with a clear ($93) so it works from a
known screen regardless of the boot banner and prompt position.
"""

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
