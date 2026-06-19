"""Pre-seed tardis overlays for VICE tests.

Overlays normally fetch from the One ROM's flash on demand; VICE has no One
ROM, so tests write the overlay image straight into its run address. The
resident thunk validates the cache by the magic in the overlay's own header,
so seeding the bytes is enough -- no resident state to poke.

The files overlay (cat/less/cp/mv/rm) and the edit overlay share $8800, so a
test that uses both must re-seed whichever it needs next.
"""

import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_OVL = os.path.join(_HERE, "..", "..", "build", "overlays")


def _seed(v, name, addr):
    with open(os.path.join(_OVL, name), "rb") as f:
        v.write_memory(addr, list(f.read()))


def seed_files(v):
    """cat / less / cp / mv / rm overlay -> $8800."""
    _seed(v, "files.bin", 0x8800)


def seed_dir(v):
    """dir / ls / pwd overlay -> $8800."""
    _seed(v, "dir.bin", 0x8800)


def seed_edit(v):
    """edit overlay -> $8800."""
    _seed(v, "edit.bin", 0x8800)


def seed_picker(v):
    """color-picker overlay (border/bg/text with no value) -> $8800."""
    _seed(v, "picker.bin", 0x8800)
