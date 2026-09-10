# Serving more than 16 KB — ROM-expansion architecture options

**Status:** design + PoC planning. Nothing built yet. Two viable routes, both
hardware-only (the One ROM isn't emulated in VICE).

## The problem

The C64 CPU sees exactly **16 KB of ROM** at any instant: the BASIC window
`$A000-$BFFF` and the KERNAL window `$E000-$FFFF`. Tardis fills both, and both
are near-full (BASIC half ~136 B free before the recent reclaim, KERNAL half
~450 B). We're out of room, and the *current* escape valve — RAM overlays — has
two real costs:

1. **They clobber user RAM.** Overlay command bodies are fetched over RBCP into
   `$8800-$9Fxx` and executed there, which stomps on any loaded program. That's
   the root of a whole class of "loaded a big game, then a command corrupted it"
   problems.
2. **They're slow to fetch.** RBCP `SLOT_PEEK` copies the overlay byte-by-byte
   with a badline guard and retries — hundreds of ms on the first call.

The goal: **run more command code than fits in 16 KB, from ROM (not user RAM),
without stomping the user's program.** The only way to exceed 16 KB is to *swap*
what one of the two windows serves. Everything hinges on what has to stay put
(static) versus what can be swapped.

Two options differ in *how* the swap-in happens:

- **Option A — swap the served set** (`SWITCH_SLOT` / `ora_set_active_ram_slot`):
  bank the BASIC window between whole ROM images. Standard One ROM feature; can
  be prototyped **today**.
- **Option B — plugin-patch a ROM window** (`ora_reprogram_ram_rom_slot`): keep
  one served image and have a plugin write the invoked command's bytes into a
  fixed window in it on demand. Needs a custom plugin (a host-control fork).

---

## Option A — swappable BASIC-half banks

### The insight that makes it tractable

You do **not** have to fit Tardis's whole static core into 8 KB. Keep the
current 16 KB image as the **base set**, and add **bank sets** that share a
*byte-identical KERNAL half* but carry a *different BASIC half*:

```
base set : [ BASIC-base  | KERNAL-static | char ]
bank 1   : [ BASIC-bank1 | KERNAL-static | char ]   <- same KERNAL + char
bank 2   : [ BASIC-bank2 | KERNAL-static | char ]
...
```

Because the KERNAL half is identical across every set, `SWITCH_SLOT` is
**live-safe**: the CPU is executing from `$E000` (KERNAL) during the swap and
sees no change — exactly the trick the `font` command already uses to swap the
char ROM under a running machine. Only the `$A000-$BFFF` window changes.

### Flow

1. The shell loop (in the base BASIC half) reads a line, dispatches.
2. For a **bank command**, it calls a small **dispatcher in the KERNAL (static)
   half**: `SWITCH_SLOT` to the bank set → `JSR` the bank's entry at `$A000` →
   `SWITCH_SLOT` back to base → return to the shell loop.
3. The bank command runs **from ROM at `$A000`** — no user-RAM clobber.

### The one real constraint: banks are self-contained

While a bank is served, the base BASIC half (shell helpers, parser, cc65
runtime, resident command bodies) is *gone* — replaced by the bank. So a bank
command may only call code that lives in the **KERNAL/static half**: the KERNAL
stubs (`$FFD2` CHROUT, `$FFE4` GETIN, file I/O), the `iec_*` primitives, screen,
and the RBCP/swap driver — via a fixed ABI. This is **exactly the discipline the
current overlays already follow** (self-contained, KERNAL-stub + SVC-table API).
So a "bank command" is a today's-overlay that happens to run from a swapped-in
ROM bank instead of from `$8800` RAM.

That reframes the whole thing: **Option A is "overlays that run from ROM."** The
migration path from the existing overlay system is short — the command bodies
are already written to the right discipline.

### Cost, and where the future API helps

- **Flash:** each bank is a full 16 KB set today (duplicate KERNAL + char). Flash
  is plentiful, so this is fine, just wasteful.
- **RAM slots:** to `SWITCH_SLOT` to a bank it must be in a RAM slot. If it's
  resident, the switch is instant; if not, `LOAD_SLOT` copies the 16 KB set
  flash→RAM first (comparable to a current overlay fetch, then instant
  thereafter). The One ROM has a handful of RAM slots, so a few banks stay hot
  and the rest page.
- **The upcoming single-ROM-in-a-3-ROM-set swap API** (a few weeks out) fixes
  both: swap just the 8 KB BASIC ROM within the set, so banks are 8 KB (half the
  flash, no KERNAL duplication) and `LOAD_SLOT` moves half the bytes. It does
  **not** change the architecture — just makes it cheaper. **We can prototype
  now with whole-set swaps and drop in the single-ROM call when it lands.**

### Wins / limits

- ✅ Runs from ROM — **no user-RAM clobber** (the headline win over RAM overlays).
- ✅ Hot banks switch in ~instantly (`SWITCH_SLOT` only).
- ✅ Uses **existing** RBCP/host-control APIs — no custom plugin, buildable today.
- ⚠️ Bank commands must be self-contained (KERNAL-API only) — same as overlays.
- ⚠️ Whole-8 KB-bank granularity; RAM-slot pressure until the single-ROM API.

---

## Option B — plugin-patched ROM window

### Architecture

Keep a single served image. Reserve a **patch window** in the served BASIC half
(say `$B000-$B7FF`, 2 KB). Move the pageable command bodies into a **flash store**
the plugin owns. On invocation, Tardis (host) asks the plugin over RBCP to page
command X in; the plugin `ora_reprogram_ram_rom_slot`s X's bytes into the window
of the **live** served slot; Tardis then `JSR`s the window — running the command
**from ROM**, no user-RAM clobber.

This is the current overlay system **evolved**: same "page a command body on
demand" idea, but (a) the code runs from a ROM window (`$Bxxx`) instead of user
RAM (`$8800`), and (b) the **plugin** does the copy (fast, DMA-side) instead of
the CPU reading each byte over RBCP.

### Wins / limits

- ✅ **No 8 KB-static split, no set duplication** — keep the 16 KB layout, just
  carve a window (freed by moving those commands to the flash store).
- ✅ **Fine granularity** (patch a few hundred bytes) and **no RAM-slot pressure**
  (one served slot, patched in place).
- ✅ Effectively unlimited command store in the plugin's flash.
- ⚠️ **Needs a custom plugin.** One ROM runs two plugins (system + user); we
  already use usb + host-control and can't drop host-control, so this must be
  **folded into a host-control fork** (see `CART-RETURN-PLUGIN.md` — same
  constraint). Model on `firmware/ora/examples`' C64 kernal-patcher.
- ⚠️ **Live-slot patch is an open question:** is `ora_reprogram_ram_rom_slot`
  safe/atomic on the *actively-served* slot, and fast enough? (We only patch a
  small window, so latency is a non-issue if it's supported at all.)
- ⚠️ A host↔plugin handshake is needed so Tardis knows the patch finished before
  it `JSR`s the window (RBCP request/response).

---

## Comparison

| | A: swappable banks | B: plugin-patched window |
|---|---|---|
| Runs from ROM (no user-RAM clobber) | ✅ | ✅ |
| Buildable **today** | ✅ (whole-set swap) | ❌ (needs plugin) |
| Needs a custom plugin | No | Yes (host-control fork) |
| Granularity | 8 KB bank | ~window (few hundred B) |
| RAM-slot pressure | Yes (until single-ROM API) | No |
| Flash cost | 16 KB/bank now, 8 KB later | ~command bytes |
| Command discipline | self-contained (KERNAL API) | self-contained (KERNAL API) |
| Depends on unreleased API | single-ROM swap (nicer, optional) | live-slot reprogram (needed) |

Both keep the same "self-contained, KERNAL-API" command discipline we already
use for overlays, so command bodies port to either with little change. They're
also **not mutually exclusive** — a mature system could keep a few hot banks
(A) *and* a fine-grained patch window (B).

## Recommendation

1. **Prototype Option A now** with whole-set swaps — it needs no plugin, proves
   the "run a command from a swapped-in ROM bank" mechanism end to end, and
   directly kills the user-RAM-clobber problem. Swap in the single-ROM API when
   it ships (cheaper, no code changes to the architecture).
2. **Keep Option B as the complement/fallback** for when 8 KB-bank granularity or
   RAM-slot pressure bites — it's the finer-grained, plugin-based tool, and it
   shares the host-control-fork work with the cart-return plugin, so building one
   lowers the cost of the other.

---

## PoC plans

### Option A PoC (buildable today)

Goal: invoke a command whose body lives in a **swapped-in BASIC bank**, running
from ROM, then return cleanly.

1. **Bank image.** A minimal `cfg/bank.cfg` + a `src/banks/hello.s` that links to
   run at `$A000`, exports a fixed entry, and prints "hello from bank" via
   `$FFD2` (KERNAL stub — present in the static half). Build it to an 8 KB
   `build/bank_hello.bin` (padded).
2. **Firmware set.** Add a bank set to the stock config: `[bank_hello.bin |
   build/kernal.bin | c64-charset]` — KERNAL + char identical to the base set.
3. **Dispatcher.** A resident `banktest` command in the KERNAL half (`CODE2`):
   reuse the `launch.s` RBCP wrappers to `LOAD_SLOT` the bank into a scratch RAM
   slot, `SWITCH_SLOT` to it, `JSR $A000`, `SWITCH_SLOT` back to the base slot.
   (This is `rbcp_cmd_switch_slot` + `load_slot`, already used by `font`.)
4. **Validate on hardware** (swap is inert in VICE): `banktest` should print the
   bank's message and return to a working prompt, with a loaded program at
   `$0801-$7FFF` left **intact** (the whole point — prove no user-RAM clobber).

De-risking: step 3's swap sequence is the same one `font 1` already runs on
hardware, so the mechanism is known-good; the new work is the bank link + entry
ABI + the base's BASIC half staying untouched while the bank runs. Open sub-
question: how many RAM slots 0.7.2 gives us for hot banks vs. `LOAD_SLOT`-per-
switch (measure with `onerom` slot info).

### Option B PoC (after the plugin exists)

Blocked on the host-control fork. Once we have a plugin building against
`firmware/ora`: add a "page command into window" RBCP op that
`ora_reprogram_ram_rom_slot`s bytes from a plugin-held store into a fixed
`$Bxxx` window of the live served slot; a resident thunk issues the op, waits for
the done response, then `JSR`s the window. Validate the same way (message +
program intact). This PoC also answers the "live-slot reprogram" open question
that both this and the cart-return plugin depend on.

## Cross-references

- `CART-RETURN-PLUGIN.md` — shares the host-control-fork plugin work and the
  live-slot-reprogram question (Option B).
- `RBCP-DESIGN.md` — the swap/`SWITCH_SLOT`/`LOAD_SLOT` machinery Option A reuses.
- The `font` command (`fs.c` / `launch.s` `_font_apply`) — the existing,
  hardware-validated live set-swap that Option A's dispatcher is modelled on.
