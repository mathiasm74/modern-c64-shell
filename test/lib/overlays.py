"""Pre-seed tardis overlays and BANKS for VICE tests.

Two mechanisms live here now. A RAM overlay is fetched to $8800; a bank is
SERVED as ROM at $A000 and seeds into the RAM underneath it (bank_call falls
back to running it from there when no One ROM answers). Most commands are banks
now -- only edit and about are still overlays.

Overlays normally fetch from the One ROM's flash on demand; VICE has no One
ROM, so tests write the overlay image straight into its run address. The
resident thunk validates the cache by the magic in the overlay's own header,
so seeding the bytes is enough -- no resident state to poke.

The files overlay (cat/less/cp/mv/rm) and the edit overlay share $8800, so a
test that uses both must re-seed whichever it needs next.

seed_disk_bank is the odd one out -- see its docstring.
"""

import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_OVL = os.path.join(_HERE, "..", "..", "build", "overlays")


def _seed(v, name, addr):
    with open(os.path.join(_OVL, name), "rb") as f:
        v.write_memory(addr, list(f.read()))


def seed_files(v):
    """files bank -> the RAM under the $A000 ROM.

    cat/less/cp/mv/rm/cd/status/border/bg/text/peek/poke/help/device/devices,
    plus the colour picker. It was a RAM overlay at $8800; it is a BANK now
    (docs/ROM-EXPANSION.md), so it seeds like the other banks. Kept under the
    old name because callers only care that the code behind those commands is
    present.
    """
    _seed_bank(v, "files_bank.bin")


def _seed_bank(v, name):
    """Write a bank image into the RAM under the $A000 ROM (see seed_disk_bank).

    Only ONE bank can be seeded at a time -- they are all linked to $A000, just
    as the RAM overlays all share $8800 -- so a test that uses two must re-seed
    between them."""
    path = os.path.join(_HERE, "..", "..", "build", "banks", name)
    with open(path, "rb") as f:
        img = f.read()
    end = len(img)
    while end > 0 and img[end - 1] == 0xFF:
        end -= 1
    v.write_memory(0xA000, list(img[:end]))


def seed_util_bank(v):
    """util bank (tab completion) -> the RAM under the $A000 ROM."""
    _seed_bank(v, "util_bank.bin")


def seed_disk_bank(v):
    """disk bank (dir / ls / pwd / fload) -> the RAM under the $A000 ROM.

    A bank is not an overlay: it is SERVED as ROM at $A000 by the One ROM, so
    there is no RAM image for a test to drop in. What makes it testable anyway
    is that the C64 has RAM *under* that ROM which the shell never uses, and
    writes to $A000-$BFFF always land in it -- so seeding works exactly like an
    overlay, and bank_call (src/rbcp/launch.s) falls back to running the bank
    from there when no One ROM answers. That fallback is what keeps the disk
    commands covered by this suite after they left the 16KB ROM.

    Only the used part is written: the image is $FF-padded to a full 8KB and
    pushing all of that through the monitor is needlessly slow.
    """
    _seed_bank(v, "disk_bank.bin")


def seed_about(v):
    """about overlay (self-contained asm pager) -> $8800."""
    _seed(v, "about.bin", 0x8800)


def seed_edit(v):
    """edit overlay -> $8800."""
    _seed(v, "edit.bin", 0x8800)


def seed_picker(v):
    """The picker rides inside the files bank now -- same image."""
    seed_files(v)
