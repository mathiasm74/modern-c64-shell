# Filename TAB completion — design spec

Status: **specced, not implemented**. Decisions below were settled with the
user (2026-07-02); the previous *command-name* completion was removed in an
earlier phase (rarely useful, resident-ROM cost) and stays out.

## Model

**The shell completes what it last saw.** `ls`/`dir` fill a resident name
cache as a free side effect of drawing their listing; TAB completes only from
that cache, instantly, with no drive I/O mid-keystroke. An empty or
invalidated cache makes TAB inert. The mental model is honest for an 8-bit
machine and cheap to teach: *list first, then complete*.

Rejected alternatives, for the record:
- *Read "$" on TAB*: always fresh, but stalls the prompt 1–3s per first TAB
  (standard IEC; the Epyx fast path can't be used mid-keystroke without the
  timed-transfer abort problems the pager already hit).
- *Overlay-based completer fetched on TAB*: keeps ROM cost near zero but puts
  an RBCP fetch (and its failure modes — "overlay load failed" mid-edit) and
  the $8800 user-RAM clobber inside a keystroke.

## UX rules

- **Trigger**: TAB ($09) with the cursor in the second or later word of the
  line. TAB in the first word: inert (command names don't complete). CTRL+I
  emits $09 and therefore behaves identically at the prompt; the `edit`
  overlay's own input loop is unaffected.
- **Word extraction**: from the character after the previous space up to the
  cursor. Text right of the cursor is ignored for matching and untouched by
  the insertion.
- **Matching**: prefix match, case-folded (the IEC layer uppercases names on
  send, so typed `ga` matches `GAMEPACK`). CBM wildcards (`*` `?`) in the
  typed prefix are literals. All entry types complete (PRG/SEQ/USR/REL and
  Meatloaf's DIR/URL — completing into a `cd` target is half the point).
- **One match**: insert the remaining characters at the cursor (the existing
  insert/redraw machinery; mid-line insertion pushes the tail right).
- **Several matches**: complete to the longest common prefix. A second TAB
  that makes no progress prints the candidates below the line in the `ls`
  two-column style, then reprints the prompt (print_device_prefix +
  prompt_str) and the line, cursor restored.
- **No matches / empty cache / first word**: nothing happens. No beep, no
  message.
- **Names with spaces** complete literally; the parser splits on spaces, so
  such names were already unusable as single args. Documented limitation.

## Cache

- Resident BSS array in the RAM segment ($C000–$C7FF): `CACHE_N = 48` entries
  x 17 bytes (len + 16 name chars) = 816 bytes, plus a count byte and a
  valid flag. **The RAM segment is 2KB shared with the cc65 C stack** — after
  implementing, check the map that BSS end leaves comfortable stack headroom;
  shrink `CACHE_N` if not. Listings longer than the cap cache the first
  `CACHE_N` names (the rest simply don't complete — no error).
- **Fill**: the `dir` overlay's `dir_line` already parses each entry to draw
  it; it also copies the quoted name into the cache. The cache base address
  and cap are passed in the dir mailbox (the `device`-thunk pattern: resident
  pointer handed to the overlay, e.g. $02D6/7 + a cap byte) so the overlay
  doesn't hardcode a BSS address that moves between builds. Both `ls` and
  `dir` fill it; `pwd` (header only) does not touch it.
- **Invalidation** (valid flag cleared): `cd`, `device`, `rm`, `mv`, `cp`,
  a SAVE via the KERNAL shim, and any dir read that ends in a drive error.
  A completed `ls`/`dir` re-validates. `load`/`run` do NOT invalidate (they
  don't change the directory).

## Code placement & budget

- **Resident** (shell.c readline, BASIC half): TAB case in the key loop —
  word extraction, cache scan, common-prefix computation, insertion, and the
  candidate listing + prompt/line reprint. Budget ~250–350 bytes against the
  ~1.7KB currently free; the two-column lister can share `ls`'s column logic
  only if that is resident (it isn't — it's in the dir overlay), so it gets a
  minimal local loop (name + pad to 20 cols, CR every second name).
- **Overlay** (dir.c): the cache-fill hook in `dir_line` + mailbox plumbing.
  Free ROM-wise (overlays live outside the 16KB).
- **Thunks** (fs.c): pass cache base/cap in the dir mailbox; clear the valid
  flag in the invalidating commands' thunks (one store each).

## Out of scope (v1)

- Path-segment completion (`games/pi<TAB>` — needs reading a non-CWD
  directory).
- Quoting/escaping names with spaces.
- Command-name completion (deliberately removed earlier; unchanged).
- Per-command argument awareness: TAB completes filenames for any argument of
  any command (`poke 53<TAB>` just finds no match — harmless).

## Test plan

- Seed the cache directly (write count + entries into the BSS address from
  labels.txt) and drive readline with injected keys — no drive needed for the
  matching/insertion/listing tests: unique match completes; common prefix
  stops at ambiguity; second TAB lists candidates and the line survives
  intact (screen rows + $D3/$D6 checks, like test_lineedit); TAB in the first
  word inert; empty cache inert; case-folded match.
- With the VICE disk attached and the dir overlay seeded: `ls` fills the
  cache (read it back from RAM); `rm`/`cd` clear the valid flag.
- Wrapped-line completion (insertion near col 40) reuses the existing
  lineedit wrap machinery — one test.
