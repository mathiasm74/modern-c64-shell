"""Disk commands must not wedge the shell when no usable disk is present.

Runs with NO disk attached (no VICE_DISK). VICE still has an empty drive 8, so
the bus answers but never returns a directory; the IEC receive timeout must
bail and leave the shell responsive. This is the hang that the timeout fixes
(typing `ls` after `make run` without attaching an image).
"""


def _type(v, text):
    v.write_memory(0x0277, [ord(c) for c in text] + [0x0D])
    v.write_byte(0x00C6, len(text) + 1)


def test_ls_without_disk_stays_responsive(v):
    _type(v, "ls")
    for _ in range(8):                  # let the read time out and report
        v.run_for(0.5)
        if "read error" in v.screen_text():
            break
    # The guarantee is that the shell survived and still runs commands; if ls
    # had wedged, this ver would never appear.
    _type(v, "ver")
    ok = False
    for _ in range(5):
        v.run_for(0.4)
        if "C64 Shell ROM v0.18" in v.screen_text():
            ok = True
            break
    assert ok, "shell did not respond after `ls` with no disk (it wedged)"
