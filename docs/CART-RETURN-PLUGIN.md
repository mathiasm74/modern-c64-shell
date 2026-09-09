# Cart-return plugin — swapping back to Tardis when a cartridge exits

**Status:** design only. Not built. Blocked on confirming the One ROM 3rd-party
plugin API (see "Open questions"). This documents the idea, the mechanism, the
constraints that make it tractable, and the two real gotchas, so we can build
against Piers' plugin SDK once we've read it.

## Problem

Tardis is served by a One ROM in the C64's KERNAL/BASIC ROM sockets. When a
physical cartridge is in the expansion port, `reset.s` detects the `CBM80`
autostart signature at `$8004` and does `jmp _rbcp_launch_stock` — it swaps the
One ROM to the **stock** ROM set and lets the *stock* KERNAL autostart the cart
(Tardis's KERNAL can't run cartridge software; it expects stock routines). See
the "Cartridge auto-detect" block in `src/reset.s`.

Consequence: once a cart is detected you are running in the **stock** environment
(the One ROM is serving stock KERNAL/BASIC). When the cart's menu "exits to
BASIC," it lands in **stock BASIC** — not Tardis. There is no way back to the
shell short of a full power cycle, because:

- The cart swap (`_rbcp_launch_stock`) is a bare swap; it does **not** install
  the RUN/STOP+RESTORE escape hook that `run`/`basic` install, so there is no
  swap-back path from inside the cart's stock environment.
- You can't reset out of it: with the One ROM now serving stock, a reset serves
  the *stock* reset vector, so `$FFFC` takes you back into stock, not Tardis.
  And even if you reached Tardis's reset, it would re-detect the cart's `CBM80`
  and swap straight back to stock — a loop.

**Goal:** when a cart in cart-mode exits back toward BASIC, transparently swap
the served ROM set back to Tardis and land in the shell.

## Why the bus-level approach is the right one

Any software approach (plant a return shim, hook a vector) fails because the
cart owns the environment: the stock reset autostarts the cart before our code
could run, and the cart is free to reuse all of RAM. There is no cooperating
Tardis code alive in the cart's environment to issue an RBCP command — which is
how the existing host-control plugin is driven.

The One ROM, by contrast, is *always* watching the address bus (that's how it
decides which byte to drive) and can switch which RAM slot it serves
(`SWITCH_SLOT`). A **bus-triggered** plugin — one that reacts to a served-range
address on its own, with no host cooperation — is the only thing positioned to
notice the exit and act on it. Third-party plugins are supported, so this is
something we can ship ourselves.

## Key constraint that (surprisingly) makes it work

The One ROM sits in the ROM sockets: it has **A0–A12 plus its chip-selects**,
and **no A13–A15**. So it can only observe accesses to the ranges it actually
serves — `$A000–$BFFF`, `$E000–$FFFF`, and the char ROM. It **cannot see the
cart's `$8000–$BFFF` space** (no CS there for it, and no high address bits to
disambiguate).

That sounds fatal but isn't, because every signature of "heading back to BASIC"
lives in a served range:

- the **reset vector** at `$FFFC/$FFFD` (KERNAL range),
- the BASIC **cold-start entry** (in the `$E000` KERNAL region on the C64),
- the BASIC **restart vector** at `$A000` (BASIC range).

So the plugin can watch for the exit even though it is blind to the cart itself.

## Mechanism (the clean version): ride the reset-vector fetch

A reset boundary is the one moment nothing is half-executed, so it is the only
*safe* place to change the served KERNAL/BASIC out from under the CPU. If the
cart exits with a soft reset (`JMP ($FFFC)` — the common case):

1. Plugin, currently serving the **stock** set in cart-mode, sees the read at
   `$FFFC`.
2. It **switches the served set back to Tardis** and serves *Tardis's* reset
   vector bytes for the `$FFFC/$FFFD` reads.
3. The CPU takes Tardis's reset address and jumps straight into Tardis's
   now-served reset — atomic, safe, no half-executed instruction.
4. Tardis's `reset.s` runs and must **skip the cart autostart this time** (else
   it re-detects `CBM80` and bounces back to stock). The plugin leaves a
   "returning from cart — skip the cart" hint in the back-channel that
   `reset.s` reads. This is a small change on our side; boot already does RBCP
   reads.

That is the whole happy path: one bus-triggered slot switch + a few lines in
`reset.s`.

## Gotcha #1 — the initial reset looks identical to the exit reset

When Tardis first hands off to a cart it does `_rbcp_launch_stock` → `JMP
($FFFC)` → stock reset. That is **also** a `$FFFC` fetch. If the plugin fired on
it, it would yank control back to Tardis before the cart ever ran.

So the plugin must **arm** its exit-watch only *after* the handoff:

- As it swaps for a cart, Tardis signals the plugin over the back-channel:
  "cart-mode — arm the return-watch."
- The plugin **ignores the immediately-following reset** (the handoff's own
  `$FFFC`) and only watches for the *next* reset-vector fetch (the cart's
  deliberate exit).

Note the initial cart boot never touches the BASIC cold-start entry either: the
stock reset autostarts the cart *before* falling through to BASIC. So a fetch of
the cold-start entry while armed is itself a strong "cart exited" signal — a
useful secondary trigger, and a fallback for carts that exit to cold-start
without a reset (but see Gotcha #2).

## Gotcha #2 — carts that don't exit via a reset

Some carts "exit to BASIC" by jumping *straight into* the BASIC cold start
rather than resetting. There is no reset boundary to ride, and flipping the
served KERNAL/BASIC out from under a running routine corrupts it (the CPU would
fetch Tardis bytes where the running stock routine expected stock bytes).

Handling that cleanly needs the plugin to **inject a redirect** — serve *custom*
bytes at the cold-start entry that bounce the CPU to Tardis's reset — rather
than merely flip a slot. Whether that's possible depends on how much
fine-grained per-address control the plugin API exposes (a single custom-byte
override at a chosen address would be enough: serve a `JMP ($FFFC)` there, with
the reset vector already pointed at Tardis).

Summary: **reset-style exits → clean (slot switch only); direct-JMP-to-BASIC
exits → hard (needs byte injection).**

## Shape of the feature

Two parts:

1. **Bus-triggered plugin (RP2350):**
   - Accept a back-channel "arm cart-return watch" command (set by `reset.s` at
     handoff).
   - While armed and serving the stock set, ignore the first reset; then watch
     for a `$FFFC` fetch (and optionally the BASIC cold-start entry).
   - On trigger: `SWITCH_SLOT` back to the Tardis set, serve Tardis's reset
     vector, set a "returned-from-cart" back-channel flag, disarm.
   - Stretch: per-address byte override for the direct-JMP case.

2. **`reset.s` (our ROM):**
   - At the `CBM80` handoff, send the "arm cart-return watch" hint before
     `_rbcp_launch_stock`.
   - At boot, read the "returned-from-cart" flag; if set, **skip** the `CBM80`
     autostart and fall through to the shell (and clear the flag).

## Interaction notes

- **Served-set numbers.** The plugin needs the flash/RAM slot of the Tardis set
  and the stock set. These already exist as constants in `launch.s`
  (`RBCP_STOCK_FLASH_SLOT`, the shell RAM slot). Keep the plugin's notion of
  them in sync with `tools/gen_overlay_pages.py`/`launch.s`, or pass them over
  the back-channel at arm time so there's a single source of truth.
- **16K / Ultimax carts.** A 16K cart maps `$8000–$BFFF` and an Ultimax cart
  `$E000`, physically overriding Tardis's own ROM window while the cart asserts
  its lines. No firmware can serve Tardis there — this feature is inherently
  limited to **8K carts** (which cover only `$8000–$9FFF`). Document this; it's
  a hardware banking fact, not a plugin limitation.
- **The Meatloaf-on-IEC caveat** from `reset.s` (cart games going black when a
  Meatloaf is on the bus) is unrelated but worth remembering while testing.
- **VICE.** The whole path is hardware-only — the One ROM (and thus the plugin
  and slot switches) isn't emulated, exactly like RBCP. Validation is on real
  hardware with a real 8K cart.

## Simpler interim (no plugin)

A **hold-a-key-at-power-on cart bypass** in `reset.s` (skip the `CBM80`
autostart if a chosen key is held → boot the shell) is achievable today with no
plugin. It is "boot Tardis *despite* the cart" rather than a true "exit the cart
*to* Tardis," and it only helps 8K carts, but it needs no firmware work and
gives an escape hatch while the plugin is designed/built.

## Open questions (resolve against Piers' plugin SDK before building)

1. Can a 3rd-party plugin **react to a specific served address** during
   byte-serving (i.e. run logic keyed on the address it's currently serving)?
2. Can it trigger a **`SWITCH_SLOT`** (or equivalent served-set change) from
   inside that reaction, within the serving timing budget?
3. Can it **override individual byte reads** at a chosen address (needed only
   for the direct-JMP-to-BASIC / injection case)?
4. What **back-channel** facilities does a 3rd-party plugin get for host↔plugin
   hints (the "arm" command and the "returned-from-cart" flag)?
5. Timing: is there headroom in the serve loop to do an address compare +
   conditional slot switch without missing a byte, or does the plugin model
   already give a clean hook for "on access to X"?

If (1) and (2) are yes, the clean reset-style version is buildable. (3) unlocks
the direct-JMP carts. (4) is needed for the arm/skip handshake but could be
worked around with a fixed RAM-cell convention if the plugin can read/write a
byte the host also sees.
