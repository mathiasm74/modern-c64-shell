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
    assert "COMMAND NOT FOUND" not in v.screen_text(), \
        "shell reported a command before anything was typed"


def test_unknown_command_reports(v):
    # "LS" + RETURN -> the shell echoes it back as an unknown command.
    _send(v, [CLEAR, 0x4C, 0x53, CR])      # L S RETURN
    v.assert_screen_contains("COMMAND NOT FOUND: LS")


def test_empty_line_reprompts(v):
    # RETURN on an empty line just reprints the prompt; no error, no dispatch.
    before = v.screen_text().count(">")
    _send(v, [CR])
    after = v.screen_text().count(">")
    assert after >= before + 1, "empty line did not produce a fresh prompt"
    assert "COMMAND NOT FOUND" not in v.screen_text(), \
        "empty line should not be treated as a command"


def test_line_editing_backspace(v):
    # Type "LZ", delete the 'Z', type 'S' -> the dispatched command is "LS".
    _send(v, [CLEAR, 0x4C, 0x5A, DEL, 0x53, CR])   # L Z <DEL> S RETURN
    v.assert_screen_contains("COMMAND NOT FOUND: LS")
    assert "COMMAND NOT FOUND: LZS" not in v.screen_text(), \
        "backspace did not remove 'Z' from the command line"


def test_screen_scrolls_under_shell(v):
    # A marker command, then enough commands to push it off the top. Each
    # "X<CR>" pair is one command; five fit in the 10-byte keyboard buffer.
    _send(v, [CLEAR, 0x5A, 0x5A, 0x5A, CR])        # "ZZZ" -> marker response
    assert "ZZZ" in v.screen_text(), "marker command response not shown"
    for _ in range(4):
        _send(v, [0x58, CR] * 5)                   # 5 "X" commands per batch
    assert "ZZZ" not in v.screen_text(), \
        "screen did not scroll the marker command off the top"
    v.assert_screen_contains("COMMAND NOT FOUND: X")   # shell still running
