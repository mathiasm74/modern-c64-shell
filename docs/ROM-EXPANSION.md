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

## PoC status & grounded increment plan

Built and verified (this is real, in-tree):

- **Increment 1 — bank build + ABI (done).** `cfg/bank.cfg` links a self-
  contained 8 KB image to run at `$A000-$BFFF` with a `$A000` JMP-table entry
  ABI; `src/banks/bank1.s` is a minimal test bank (entry 0 prints "hello from
  rom bank 1" via the static `$FFD2` CHROUT, touches no writable memory).
  `make banks` → `build/banks/bank1.bin` (8 KB, first bytes `4C 03 A0` = the
  entry JMP). This is the verifiable foundation; the swap itself is hardware-
  only so the remaining increments are validated on the C64.

The mechanism is grounded in existing, hardware-validated code:

- The swap is the **`font` path**: `rbcp_font_tramp` (launch.s) already does
  `enter CR → LOAD_SLOT (A=RAM slot, X=flash slot) → SWITCH_SLOT → exit CR`,
  running from the RBCP RAM block, live, with the CPU executing from the
  unchanging KERNAL half. A bank dispatcher is the same primitive applied twice.

Remaining increments:

- **Increment 2 — dispatcher + swap-back.** A resident `bank_call(bank, index)`
  in the **KERNAL/static half** (survives the swap): set the font-style mailbox
  (flash slot, RAM slot), call a `bank_tramp` (a near-clone of `rbcp_font_tramp`)
  that `LOAD_SLOT`+`SWITCH_SLOT`s the bank in, `JSR $A000 + 3*index`, then
  `SWITCH_SLOT`s back to the base RAM slot 0. Add a `banktest` command that
  calls `bank_call(BANK1, 0)`. Two RBCP transactions (in, out) per invocation.
- **Increment 3 — firmware set + hardware bring-up.** Add a bank set to the
  stock config: `[bank1.bin | build/kernal.bin | c64-charset]` — KERNAL + char
  byte-identical to the base set so `SWITCH_SLOT` is live-safe. Pick its RAM
  scratch slot (font B uses slot 2; find a free one, or `LOAD_SLOT` on demand).
  Flash; `banktest` must print the banner **and** leave a program loaded at
  `$0801-$7FFF` intact (the run-from-ROM, no-user-RAM-clobber proof).
- **Increment 4 — move the fast loader (the pressure proof).** *De-risked:* the
  timed receive is a single call — `fast_receive_prg` calls `_epyx_recv_prg`
  (fastload_recv.s), whose sample loop runs internally. So the **timing-critical
  ASM stays RESIDENT** in the KERNAL half (shared with the fast-dir overlay via
  the SVC table already), and only the **non-timing orchestration glue** moves
  to a bank: `fold_name`, the install/header sequence, the `recv_prg` call,
  the drive-still-there verify, and the report. There is no timing risk, because
  no timed code is banked.

  Shape:
  1. Expose the primitives the glue needs but the dir-tailored table lacks:
     `_epyx_recv_prg` (0-arg, whole-PRG receive) as a direct SVC entry, and a
     `send_header_mb` **mailbox wrapper** for the named header — SVC routines are
     capped at ONE arg (overlay vs resident run on separate cc65 stacks, so a
     stack-passed 2nd arg is garbage; svc 12 is already the `$`-header wrapper
     for exactly this reason), so the 2-arg `send_header(name,len)` can't be a
     plain entry — the wrapper reads the folded name from the mailbox. There's
     room: SVC entries sit at `$FF80` and the file-I/O stubs begin at `$FFBA`,
     leaving `$FFB0-$FFB9` (3 more entries) free.
  2. A **C loader bank** (`src/banks/loader.c` + a `$A000` crt0/cfg, modelled on
     the overlay crt0 but linked to ROM at `$A000` instead of RAM at `$8800`):
     `loader_main` reads a small mailbox (device + filename pointer), runs the
     fload sequence via SVC + `$FFD2`, and writes `load_start`/`load_end` + a
     status back to the mailbox. No writable state at `$A000` (it's ROM); the
     mailbox and the C stack live in normal RAM.
  3. Base `cmd_fload` and `cmd_run` set the mailbox and `bank_call` the loader,
     then read the result. **Both** must route through it, or the resident copy
     stays and nothing is freed.
  4. **Measure `make` free-byte deltas** before/after — the glue that leaves the
     16 KB (`fold_name` ~112, `fload_program` ~170, `fast_receive_prg` ~75, the
     `cmd_fload` report) is the pressure-relief proof; the timed ASM stays put.

  Hardware validation is a normal `fload`/`run <name>` (the swap is inert in
  VICE). Data-driven dispatch (command table in the bank, not the base) is the
  follow-on that takes per-command cost off the 16 KB entirely.

  **Attempted and reverted — the fast loader is a BAD bank candidate.** Built it,
  measured it, backed it out. Two reasons, both important lessons:
  1. **Nil saving.** The fast loader's *bulk* — the timed Epyx protocol
     (`fastload_recv/send`, ~430 B) and the M-E/M-W install — is **shared with
     the dir overlay via SVC and must stay resident**. Only the thin
     orchestration (~245 B) could move, and that was almost exactly cancelled by
     the plumbing the move ADDS (mailbox glue + a `send_header_mb` wrapper + 2
     SVC entries + the dispatcher): net free-byte change ≈ **+6 bytes**.
  2. **Lost testability.** Routing `fload`/`run <name>` through a bank makes them
     **hardware-only** (the swap is inert in VICE), so `test_run_arg` could no
     longer exercise the fast-load path — a real regression for a command that
     had VICE coverage.

  **The lesson — don't split a cluster.** The protocol didn't *have* to stay
  resident; it stayed resident because I moved only `fload` and left its
  co-user `dir` calling it through SVC. A bank is served as a whole window and
  only one is served at a time, so:

  > **Code that calls each other must be in the same bank (or the callee must be
  > resident). Resident = the universally-shared primitives everything uses
  > (`iec_*`, screen, dispatch, RBCP). Banks = clusters of commands + their
  > *private* helpers.**

  The Epyx protocol + `fload` + `run`'s fast path + `dir` form one cluster (they
  call only each other and the resident `iec_*`). The right move is a single
  **"disk bank"** holding all of them; then the ~430 B protocol + the install +
  the glue all leave the 16 KB — a real saving. (Two caveats: `dir` is already a
  RAM overlay, so *its* body is already out of the 16 KB — the NEW bytes freed
  are the resident protocol/install; and the protocol is ROM-to-ROM either way,
  swapped in once before the timed transfer, so no timing risk.)

  My single-`fload` attempt failed precisely because it split that cluster.

  **Scope reality for the disk bank (checked in dir.c):** `dir` is not dormant —
  `dir_begin(1)` is live, and dir's receive loop calls `svc_epyx_recv_byte` /
  `svc_epyx_wait_ready` **per byte**. A per-byte receive can't be a bank call
  (no per-byte window swap), so the receiver must sit in the *same served
  window* as dir's loop. But `dir` is a **C overlay running from RAM at
  `$8800`**, calling the receiver in resident ROM via SVC. Banking the receiver
  therefore forces **converting the whole dir C-overlay into a `$A000` ROM bank**
  (new crt0, BSS/state relocated to RAM since the bank is ROM) and folding the
  `fload`/`run` fast path in with it. That is a large refactor across *every*
  disk command, hardware-only to validate, for a one-time ~430–700 B saving.
  Weigh it against data-driven dispatch, which addresses the *ongoing* pressure
  and is lower-risk.

  So the two real levers are: **(a)** move whole *clusters* into banks (the disk
  bank frees the resident fast-load code, at the refactor cost above); and
  **(b) data-driven dispatch** —
  future commands living entirely in banks with their command table in the bank,
  so a new command costs ~0 base bytes (the true answer to "new functionality
  keeps filling the 16 KB"), plus the run-from-ROM/no-`$8800`-clobber win. The
  `banktest` PoC proves the mechanism; the disk-bank cluster and data-driven
  dispatch are the two things that actually move the needle.

## The disk bank — BUILT (v0.1.88)

Built, measured, and green on the full VICE suite. The cluster rule above is
what made it work, and the measured reclaim beat the ~430–700 B estimate:

| | free before | free after | delta |
|---|---|---|---|
| BASIC half | 253 | 301 | **+48** |
| KERNAL half | 518 | 1688 | **+1170** |
| total | 771 | 1989 | **+1218** |

What left the 16 KB: the Epyx protocol (`fastload_recv.s` + `fastload_send.s`),
`fastload.c` (including the M-W/M-E install payload), the `fload`/`run` fast
path out of `fs.c`, the SVC Epyx entries, and the boot-time descramble-table
generator in `reset.s`. `dir`/`ls`/`pwd` moved too, but as they were already a
RAM overlay they freed nothing directly — moving them is what *allowed* the
protocol to leave, which is the whole point of the cluster rule.

### What it looks like

- `src/banks/` — `crt0_disk.s` (the `$A000` JMP table + per-entry init),
  `disk_bank.c` (entry glue + the fload body), `dir.c` (moved), `svc.h`,
  `bank_svc_alias.s`; `cfg/disk_bank.cfg` links them at `$A000` with state in
  the `$98xx-$9Fxx` RAM the overlays used to run from.
- `bank_call(entry)` in `launch.s` (KCODE, the static half) does the swap, and
  `fs.c` keeps only thunks.
- Firmware set 8 is `[kernal | char | disk_bank]` — KERNAL and char
  byte-identical to the base, so `SWITCH_SLOT` is live-safe.

### Three things worth knowing before building another bank

**1. Moving a cluster can need zero source changes.** `dir.c` (567 lines) and
`fastload.c` moved without edits, by binding their names differently at link
time: `bank_svc_alias.s` aliases the Epyx `svc_*` names onto the bank's own
local copies (pure symbol aliases — zero bytes, and a direct `jsr`, which the
cycle-counted receive path needs), while `cfg/disk_bank.cfg` binds the `iec_*`
names to the resident SVC slots. Prefer this to editing the sources: it keeps
one copy of code that is shared between two builds.

**2. A bank is still testable in VICE — this was not obvious.** A bank is served
ROM, so unlike a RAM overlay the harness cannot seed it, which would have made
every disk command hardware-only and cost the suite its best coverage. The way
out is that the C64 has RAM *under* the `$A000` ROM which the shell never uses,
and writes to `$A000-$BFFF` always land in it. So `bank_call` tries the One ROM
swap first and **falls back to running the bank from that RAM** (LORAM off),
guarded by a `"dsk1"` magic so garbage RAM reports "unavailable" instead of
executing. `seed_disk_bank()` writes the image there exactly as it seeds an
overlay. Result: **143 tests pass, the same count as before the move** — no
coverage was traded away. Build this fallback into any future bank.

**3. Bank RAM is not yours between calls.** The shell, a loaded program, or an
overlay may have used `$98xx-$9Fxx` in the meantime, so `bank_init` runs
`zerobss` + `copydata` + the descramble-table rebuild on *every* entry. The
resident build generated that table once at boot; a bank cannot assume that.

Still hardware-only to validate: the served path itself (the RAM fallback is
what VICE exercises). Check `dir`, `ls`, `pwd`, `fload <name>`, and
`run <name>` on the One ROM.

## Data-driven dispatch — BUILT (v0.1.92)

Lever (b), the one that addresses the *ongoing* pressure rather than another
one-off. A dispatch-table row can now name a **bank entry** instead of a
resident function, so a bank command has **no resident code at all** — only its
row:

```c
    { "ls",     BANK_CMD(1) },     /* 4-byte row + "ls\0". No thunk. */
```

`BANK_CMD(n)` stores the small entry index in the handler slot; real code never
lives in page zero, so a handler below `$0100` is unambiguously an index
(`IS_BANK_CMD`). `dispatch()` routes those through one shared
`bank_dispatch()` (fs.c), which publishes the default device, its remembered
name, and **argc/argv** — so the bank parses its own arguments and reports its
own errors.

**Cost of a new bank command: a 4-byte row plus its name.** Previously each also
needed a resident thunk (11–170 bytes) to marshal arguments and report.

Reclaimed by converting the five existing bank commands (dir/ls/pwd/fload/load):

| | free before | free after | delta |
|---|---|---|---|
| BASIC half | 955 | 1131 | **+176** |
| KERNAL half | 1563 | 2132 | **+569** |
| total | 2518 | 3263 | **+745** |

Gone: `dir_run`, the three dir thunks, `cmd_load`, `cmd_fload`, `fload_program`,
`fold_name`, and the resident `print_hex16`/`report_no_device`/
`report_drive_status` they kept alive. `run` stays resident (it drives the stock
swap) and simply calls entry 3 for its fast load.

### Why the NAME stays resident

The tempting next step is to move the name table into the bank too, for a
literal zero-byte command. Don't, for two reasons:

1. **`help` stays one sorted list.** It walks the resident table; split the
   names and it must merge two sources with a column layout, or print two
   groups.
2. **"Unknown" and "unavailable" are different answers.** With the row resident,
   `ls` on a machine with no One ROM reports *disk bank unavailable* — true and
   actionable. With the name in the bank it would report *Command not found*,
   which is simply false. `test_shell::test_bank_command_is_known_not_unknown`
   pins this.

A 4-byte row is a cheap price for both.

Order rationale: 2–3 prove the mechanism cheaply and safely; 4 is the payoff but
the riskiest (timing + `run` coupling + hardware-only), so it goes last, on top
of a proven dispatcher.

## Cross-references

- `CART-RETURN-PLUGIN.md` — shares the host-control-fork plugin work and the
  live-slot-reprogram question (Option B).
- `RBCP-DESIGN.md` — the swap/`SWITCH_SLOT`/`LOAD_SLOT` machinery Option A reuses.
- The `font` command (`fs.c` / `launch.s` `_font_apply`) — the existing,
  hardware-validated live set-swap that Option A's dispatcher is modelled on.
