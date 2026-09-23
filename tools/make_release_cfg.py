#!/usr/bin/env python3
"""Derive the RELEASE One ROM config from the development one.

    tools/make_release_cfg.py cfg/onerom-stock.json OUT.json

The development config (cfg/onerom-stock.json) offers JiffyDOS in the C= boot
menu, from a user-supplied file in stock-roms/. JiffyDOS is commercial, so a
published image must not carry it. It cannot simply be DROPPED either: the flash
set numbers are baked into the ROM (bank_flash_set and RBCP_STOCK_FLASH_SLOT in
src/rbcp/launch.s, FONTB_FLASH_SET in fs.c), and removing a set shifts every
later one. So its chip becomes the stock KERNAL, labelled with the `~` prefix
the boot menu hides -- a placeholder that keeps the numbering. v0.2.37 and
v0.3.00 were released this way, by hand.

Generated rather than kept as a second config, so it can never drift from the
development layout.
"""

import json
import sys

STOCK_KERNAL = ("https://www.zimmers.net/anonftp/pub/cbm/firmware/computers/"
                "c64/kernal.901227-03.bin")


def main(src, dst):
    with open(src) as f:
        cfg = json.load(f)
    replaced = 0
    for chip_set in cfg["chip_sets"]:
        for chip in chip_set["chips"]:
            if "jiffy" in chip.get("file", "").lower():
                chip["file"] = STOCK_KERNAL
                chip["label"] = "~reserved"
                replaced += 1
    if replaced != 1:
        sys.exit("%s: expected exactly one JiffyDOS chip, found %d -- the "
                 "layout changed; update tools/make_release_cfg.py"
                 % (src, replaced))
    cfg["description"] = ("RELEASE build (tools/make_release_cfg.py): the "
                          "JiffyDOS set is a hidden stock-KERNAL placeholder. "
                          + cfg.get("description", ""))
    with open(dst, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: make_release_cfg.py <onerom-stock.json> <out.json>")
    main(sys.argv[1], sys.argv[2])
