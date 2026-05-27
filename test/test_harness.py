"""Self-test of the harness plumbing: memory writes and keyboard injection.

These exercise the harness itself rather than ROM behavior, so the write
helpers are trusted by later tests (e.g. once Phase 3 consumes the keyboard
buffer).
"""


def test_write_readback(v):
    v.write_memory(0xC000, [0xDE, 0xAD, 0xBE, 0xEF])
    v.assert_memory_equals(0xC000, [0xDE, 0xAD, 0xBE, 0xEF])


def test_inject_keys(v):
    v.inject_keys("LOAD")
    # PETSCII for L, O, A, D, and a buffer count of 4.
    v.assert_memory_equals(0x0277, [0x4C, 0x4F, 0x41, 0x44])
    v.assert_memory_equals(0x00C6, [0x04])
