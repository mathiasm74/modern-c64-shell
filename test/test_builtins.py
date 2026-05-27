"""The built-in commands: help, clear, echo, ver, exit (Phase 5).

Each test injects a command into the keyboard buffer (the path GETIN reads)
and asserts on the shell's response. Most start with a clear ($93) keystroke
so the command runs from a known, empty screen regardless of the boot banner.

To tell a command's *output* apart from the shell echoing the typed input
(readline echoes every character), the echo tests count occurrences: a word
typed as an argument and then printed by the command appears at least twice.

Harness limit: the C64 keyboard buffer is 10 bytes, so an injected line --
including the leading clear and the trailing RETURN -- can be at most 10
characters. That is enough for every built-in but too short to exercise the
parser's quoted-string handling or its behavior on very long (truncated)
lines; those are covered by reading the code, not by an integration test.
"""

CLEAR = 0x93
CR = 0x0D


def _type(v, text):
    """Clear the screen, type `text`, press RETURN."""
    codes = [CLEAR] + [ord(c) for c in text] + [CR]
    assert len(codes) <= 10, "line exceeds the 10-byte keyboard buffer: %r" % text
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def _type_no_clear(v, text):
    """Type `text` and press RETURN without clearing first."""
    codes = [ord(c) for c in text] + [CR]
    assert len(codes) <= 10, "line exceeds the 10-byte keyboard buffer: %r" % text
    v.write_memory(0x0277, codes)
    v.write_byte(0x00C6, len(codes))
    v.run_for(0.3)


def test_help_lists_every_command(v):
    # help reads the dispatch table, so it names every registered command.
    _type(v, "HELP")
    txt = v.screen_text()
    assert "COMMANDS" in txt, "help did not print its header"
    for name in ("HELP", "CLEAR", "ECHO", "VER", "EXIT"):
        assert name in txt, "help did not list %s" % name


def test_ver_prints_version(v):
    _type(v, "VER")
    v.assert_screen_contains("C64 SHELL ROM V0.1")


def test_echo_prints_arguments(v):
    # "ECHO A B" -> the args print as "A B" (single-spaced). The typed line is
    # echoed too, so "A B" should appear at least twice; once would mean echo
    # produced nothing.
    _type(v, "ECHO A B")
    assert v.screen_text().count("A B") >= 2, "echo did not print its arguments"


def test_exit_says_nowhere_to_go(v):
    _type(v, "EXIT")
    v.assert_screen_contains("NOTHING TO EXIT TO")


def test_clear_command_wipes_screen(v):
    # First put something on screen, then let the CLEAR *command* (not a clear
    # keystroke) wipe it.
    _type(v, "ECHO ZAP")
    assert "ZAP" in v.screen_text(), "echo output should be on screen first"
    _type_no_clear(v, "CLEAR")
    assert "ZAP" not in v.screen_text(), "CLEAR command did not wipe the screen"


def test_leading_whitespace_still_dispatches(v):
    # The parser skips leading whitespace, so " VER" still finds VER.
    _type(v, " VER")
    v.assert_screen_contains("C64 SHELL ROM V0.1")
    assert "COMMAND NOT FOUND" not in v.screen_text(), \
        "leading space should not turn a known command into an unknown one"
