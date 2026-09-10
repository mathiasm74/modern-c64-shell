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

## What the plugin API actually allows (`firmware/ora/api.h`)

Read the header before committing to a mechanism; the reality changes the shape.
Plugins are C binaries that run on the free CPU cores (serving is PIO+DMA), get
a `ora_lookup_fn` to reach firmware facilities, run their own main loop, and
`ora_yield` to cooperate with the other core. There is a **C64 kernal-patcher
example** in `firmware/ora/examples/` — the closest existing thing to what we
want; follow it.

The relevant capabilities:

- **Monitor modes:** `ORA_MONITOR_MODE_OBSERVE` (passive), `..._CONTROL`
  (the plugin "takes control of what One ROM serves, modifying or replacing the
  ROM image"), and `..._OVERRIDE` ("take over individual read cycles") — the
  last is **not yet implemented**.
- **The address monitor is a polling FIFO ring buffer**, not a per-address
  callback. You configure it, start it, and poll the DMA write position (or
  `ora_wait_for_knock` blocks until a knock pattern appears in the ring — this
  is how RBCP spots its command frames). So you always learn about an access a
  few cycles *after* it happened.
- **Patch the served image:** `ora_reprogram_ram_rom_slot` updates a contiguous
  region of the RAM slot currently being served (pin mapping applied for you);
  `ora_read_ram_rom_slot` reads it back.
- **Switch the served set:** `ora_set_active_ram_slot` "atomically switches the
  ROM image being served to the host to the specified RAM slot."
- **No host↔plugin back-channel beyond RBCP.** Metadata/GPIO are device→plugin.

The consequence for us: **the elegant "serve Tardis's reset vector for the exact
`$FFFC` read" needs OVERRIDE mode, which isn't implemented.** The monitor is
observe-after-the-fact, so we can't change what a specific read returns in real
time. A plain observe-then-`set_active_ram_slot` is worse than useless: by the
time the FIFO shows `$FFFC` was read, the CPU has already latched the *stock*
vector and jumped to the *stock* reset address — switch the slot now and it
executes Tardis's bytes at a stock address → garbage.

## Mechanism (revised): pre-patch the served stock image with a return stub

CONTROL mode + `ora_reprogram_ram_rom_slot` give the real lever: **modify the
served stock ROM image so the cart's exit lands in a small 6502 stub we inject,
which swaps back to Tardis via RBCP.** No real-time interception needed.

1. Tardis detects the cart and swaps to the stock set as today
   (`_rbcp_launch_stock`), but first tells the plugin (over RBCP — see the
   two-plugin note) "cart-mode: arm the return."
2. The cart boots normally off the *unpatched* stock reset path (CBM80
   autostart). **We must not patch the reset vector before this**, or the
   initial boot would hit our stub instead of the cart.
3. Once the cart is up, the plugin patches the served stock image:
   - inject a small return stub into stock ROM **dead space** — the C64 KERNAL
     has ~28 unused `$AA` bytes at `$E4B7-$E4D2` (and BASIC ~30 at `$BF53`); the
     stub is only a few bytes (issue the RBCP switch-to-Tardis sequence, then
     `JMP ($FFFC)`);
   - repoint the reset vector `$FFFC/$FFFD` at the stub.
   Both are `ora_reprogram_ram_rom_slot` writes to the served stock slot.
4. The cart exits via `JMP ($FFFC)` → our stub → RBCP swap to the Tardis set →
   Tardis reset.
5. Tardis's `reset.s` must **skip the cart autostart this time** so it doesn't
   re-detect `CBM80` and bounce back. A RAM flag distinguishes it (set by the
   stub / cleared on cold power-on), or the swap-back sequence itself carries
   the hint.

Timing of step 3 ("cart is up") is the crux — see Gotcha #1.

Note this reuses machinery we already have: the RBCP swap-back is exactly what
`rbcp_escape_tramp` does, and the injected stub is a cousin of the `run` stub.

## Gotcha #1 — *when* to patch (the initial boot must stay unpatched)

The reset vector can't be patched until the cart has booted, because the cart's
own autostart rides the stock reset path. So the plugin has to detect
"cart is up" before it patches. Options, easiest to most precise:

- **Delay:** patch a fixed interval after the arm/handoff (a cart's menu is up
  within a fraction of a second). Crude but simple, and the window before a user
  could exit is huge.
- **KERNAL-activity watermark:** the plugin can't see the cart at `$8000`, but
  it *can* see the cart calling the KERNAL — `CHROUT`/screen/keyboard reads are
  in served ranges. Wait until N such accesses have gone by (the initial reset
  sequence has a known, bounded shape), then patch. More precise, still simple.
- **Watch the initial reset settle:** the handoff's own `$FFFC` read is the
  first thing in the FIFO after arming; ignore it, then patch once traffic
  moves past the reset sequence.

The RAM flag that tells `reset.s` "skip the cart this time" has the same
cold-vs-warm concern: it must survive the cart's exit but be clear on a true
cold power-on. A dedicated NV cell (we already use the One ROM NV for settings)
or a magic RAM signature checked against a power-on RAM pattern both work.

## Gotcha #2 — cart exit styles (pre-patching covers more than the reset-ride would)

Pre-patching is actually *stronger* than the abandoned reset-vector-ride here:
because we're editing the served image, we can repoint **every** "back to BASIC"
entry the cart might use, not just `$FFFC`:

- `$FFFC/$FFFD` — soft-reset exits.
- `$A000/$A001` — the BASIC **restart** vector (warm exits jump through it).
- the BASIC **cold-start** entry in the `$E000` KERNAL region.

Point them all at the same injected stub and both reset-style *and*
direct-JMP-to-BASIC exits funnel into it. The one thing we can't catch is an
exit that neither resets nor touches a BASIC entry vector (a cart that does its
own thing) — but "exit to BASIC" by definition goes through one of these.

The remaining hard case is purely **safety of the running CPU**: for a
direct-JMP exit the CPU is mid-flow when it reaches the patched entry, but since
we only changed the *target bytes at that entry* (not the code the CPU is
currently executing), it lands on our stub cleanly — the stub then does the RBCP
swap. This is fine as long as the stub itself lives in dead space we injected
and doesn't disturb anything the cart still needs. Validate per cart.

## The two-plugin limit — fold this into host-control, don't add a third

One ROM runs **two plugins at once** (one system + one user, by resource class).
We already use **usb** (system) and **host-control / RBCP** (user), and we can't
drop host-control — the whole overlay/swap/NV story depends on it. So the
cart-return logic can't be a *third* plugin; it has to be **added to a fork of
the host-control (user) plugin** — one combined user plugin that does RBCP *and*
the cart-return watch/patch. That's fine (3rd-party user plugins are supported,
and we'd be building our own), but it means vendoring/forking Piers'
host-control plugin source rather than writing a clean-slate plugin. Worth
confirming with Piers whether he'd take the cart-return watcher upstream into
host-control instead, so we don't carry a fork.

## Shape of the feature

Two parts:

1. **Plugin (folded into our host-control fork, `firmware/ora` C):**
   - Accept an RBCP "arm cart-return, stock-set = N, tardis-set = M" command
     that Tardis issues just before `_rbcp_launch_stock`.
   - While armed, wait for the cart to be up (Gotcha #1), then
     `ora_reprogram_ram_rom_slot` the served stock slot: inject the return stub
     into KERNAL dead space (`$E4B7`) and repoint `$FFFC`, the `$A000` restart
     vector, and the BASIC cold-start entry at it.
   - The stub (running as 6502 on the C64) issues the RBCP swap-to-Tardis; the
     plugin services it with `ora_set_active_ram_slot` like any other switch,
     and sets the "returned-from-cart" hint.
   - Model it on the `firmware/ora/examples` **C64 kernal patcher**.

2. **`reset.s` (our ROM):**
   - At the `CBM80` handoff, issue the "arm cart-return" RBCP command before
     `_rbcp_launch_stock`.
   - At boot, read the "returned-from-cart" hint (NV cell); if set, **skip** the
     `CBM80` autostart and fall through to the shell (and clear it).

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

## Open questions (answered vs. remaining)

Answered by `firmware/ora/api.h`:

- **Per-address reaction?** Only via a **polling FIFO** (address-monitor ring
  buffer), not a synchronous per-read hook — so no real-time byte substitution.
  (`ORA_MONITOR_MODE_OVERRIDE` would give per-read-cycle control but is **not yet
  implemented**.) → This is why the design pre-patches instead of intercepting.
- **Switch the served set from the plugin?** Yes — `ora_set_active_ram_slot`
  (atomic).
- **Modify served bytes at runtime?** Yes — `ora_reprogram_ram_rom_slot` /
  `ora_read_ram_rom_slot`. This is the core lever.
- **Back-channel?** Nothing beyond RBCP — hence arm/skip go over RBCP, which is
  why cart-return must live in the host-control plugin.

Remaining, to settle before/while building:

1. **`ora_reprogram_ram_rom_slot` on the *actively-served* slot** — is patching
   the live stock image (not a background slot) safe/atomic w.r.t. an in-flight
   serve, and how many bytes/how fast? (We only patch a vector + a few stub
   bytes, so latency is fine, but confirm live-slot writes are supported.)
2. **Cart-up detection** (Gotcha #1) — pick delay vs KERNAL-activity watermark
   after seeing what the FIFO actually looks like during a real cart boot.
3. **The two-plugin question** — will Piers take the cart-return watcher into
   host-control upstream, or do we vendor a fork? (Affects maintenance, not
   feasibility.)
4. **Per-cart validation** — which real 8K carts exit via `$FFFC` vs the `$A000`
   restart vs cold-start, and does the injected stub disturb anything they still
   rely on. Hardware-only, per cart.

Net: with `ora_reprogram_ram_rom_slot` + `ora_set_active_ram_slot` confirmed, the
**pre-patch-the-served-stock-image** version is buildable today (folded into
host-control), for **8K carts** (the 16K/Ultimax hardware limit stands). The
`OVERRIDE`-based real-time version is a cleaner future option if/when Piers
implements that mode.
