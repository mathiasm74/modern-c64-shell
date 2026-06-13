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
    _type(v, "help")
    txt = v.screen_text()
    assert "Commands" in txt, "help did not print its header"
    for name in ("help", "clear", "echo", "ver", "exit"):
        assert name in txt, "help did not list %s" % name


def test_ver_prints_version(v):
    # The one place the exact version is asserted; bump here on a version change.
    _type(v, "ver")
    v.assert_screen_contains("C64 Shell ROM v0.23")


def test_echo_prints_arguments(v):
    # "echo a b" -> the args print as "a b" (single-spaced). The typed line is
    # echoed too, so "a b" should appear at least twice; once would mean echo
    # produced nothing.
    _type(v, "echo a b")
    assert v.screen_text().count("a b") >= 2, "echo did not print its arguments"


def test_exit_says_nowhere_to_go(v):
    _type(v, "exit")
    v.assert_screen_contains("Nothing to exit to")


def test_clear_command_wipes_screen(v):
    # First put something on screen, then let the clear *command* (not a clear
    # keystroke) wipe it.
    _type(v, "echo zap")
    assert "zap" in v.screen_text(), "echo output should be on screen first"
    _type_no_clear(v, "clear")
    assert "zap" not in v.screen_text(), "clear command did not wipe the screen"


def test_leading_whitespace_still_dispatches(v):
    # The parser skips leading whitespace, so " ver" still finds ver.
    # Version-agnostic (exact version lives in test_ver_prints_version).
    _type(v, " ver")
    v.assert_screen_contains("C64 Shell ROM v")
    assert "Command not found" not in v.screen_text(), \
        "leading space should not turn a known command into an unknown one"
