# Filename TAB completion — design spec

Status: **implemented in v0.1.58**. Decisions were settled with the user
(2026-07-02); the previous *command-name* completion was removed in an earlier
phase (rarely useful, resident-ROM cost) and stays out. Implementation
deviations from the original draft are folded in below and marked (as-built).

## Model

**The shell completes what it last saw.** `ls`/`dir` fill a fixed-address name
cache as a free side effect of drawing their listing; TAB completes only from
that cache, instantly, with no drive I/O mid-keystroke. An empty or
invalidated cache makes TAB inert. The mental model is honest for an 8-bit
machine and cheap to teach: *list first, then complete*.

Rejected alternatives, for the record:
- *Read "$" on TAB*: always fresh, but stalls the prompt 1–3s per first TAB
  (standard IEC; the Epyx fast path can't be used mid-keystroke without the
  timed-transfer abort problems the pager already hit).
- *Overlay-based completer fetched on TAB*: originally rejected because the
  RBCP transport glitched intermittently and a failed fetch would splatter
  "overlay load failed" mid-line-edit. **Superseded (v0.1.95): the matcher now
  lives in the UTIL BANK** (docs/ROM-EXPANSION.md), which answers the objection
  rather than accepting it. A bank is *served as ROM*, not fetched into RAM, so
  there is no fetch to fail and -- the point that killed the overlay idea --
  nothing is clobbered: the util bank needs no cc65 runtime at all, so a TAB
  press costs **zero bytes of user RAM**. A bank that cannot be reached leaves
  TAB silently inert, exactly as required for a keystroke. `_line` is pinned at
  $C000 (cfg/rom.cfg LINEBUF) so the bank can index it directly, and
  `print_prompt` is reimplemented inside the bank -- it could NOT be an SVC
  entry, because SVC entries are JMPs and the resident prompt lives in the
  BASIC half, which is swapped out while a bank runs.

## UX rules

- **Trigger**: TAB ($09) with the cursor in the second or later word of the
  line. **(as-built) The C64 has no TAB key, so a bare CTRL tap emits $09**:
  `ctrl_tap` in irq.s arms when CTRL goes down with nothing else pressed,
  spoils if any key is seen while it is held (CTRL+letter combos are
  unaffected), and emits on release. CTRL+I also still emits $09. TAB in the
  first word: inert (command names don't complete). The `edit` overlay's own
  input loop is unaffected (a stray $09 there was already producible).
- **Word extraction**: from the character after the previous space up to the
  cursor. Text right of the cursor is ignored for matching and untouched by
  the insertion.
- **Matching**: prefix match, case-folded (the IEC layer uppercases names on
  send, so typed `ga` matches `GAMEPACK`). CBM wildcards (`*` `?`) in the
  typed prefix are literals. All entry types complete (PRG/SEQ/USR/REL and
  Meatloaf's DIR/URL — completing into a `cd` target is half the point).
- **One match**: insert the remaining characters at the cursor (the existing
  insert/redraw machinery; mid-line insertion pushes the tail right).
- **Several matches**: complete to the longest common prefix. (as-built) A
  TAB that makes **no progress** prints the candidates below the line in the
  `ls` two-column style, then reprints the prompt (print_prompt in shell.c)
  and the line, cursor restored -- usually that is the second TAB, but a TAB
  whose word is already the full common prefix lists immediately.
- **No matches / empty cache / first word**: nothing happens. No beep, no
  message.
- **Names with spaces** (since v0.1.70): the word under the cursor is
  quote-aware -- inside an open `"` it may contain spaces. Completing a
  spaced name from an unquoted word auto-inserts the opening quote at the
  word start (the parser groups quoted tokens; an unclosed quote parses to
  end of line), and a unique completion appends the closing quote. The
  ambiguous case extends to the common prefix inside the opened quote.

  Two rules were sharpened after hardware use (v0.1.96/97):
  - The opening quote goes in as soon as a spaced name is among the
    **candidates**, not merely when the common prefix contains a space.
    Quoting on the prefix alone broke as soon as a third name shortened the
    prefix below the space: nothing was quoted, and typing the rest (" bb")
    then began a NEW word, so completion hunted for a name starting "bb".
    Shifted space ($A0) counts, being just as much a word break to the parser.
  - TAB on a **fully-typed** unique name inside an open quote adds the closing
    quote, though there is nothing left to complete -- until the quote closes,
    the parser runs it to end of line and no further argument can be typed.

## Cache

- **(as-built) Fixed pages $CE00-$CFFF** -- free since the single-page
  overlay loader was removed -- NOT the BSS array the draft proposed: BSS
  ends at ~$C618 and the 2KB RAM segment is shared with the cc65 C stack, so
  an 800+ byte array did not fit. Layout: `$CE00` valid flag, `$CE01` count,
  `$CE02..` packed `[len][chars]` entries, capped at 509 packed bytes (~40
  names -- one page proved too small the first time a networked Meatloaf
  folder listed 40 files). Walk offsets are 16-bit on both sides. $CF00
  doubles as the run stub's home: launch_stock_program invalidates the cache
  before planting it (the machine is leaving the shell anyway).
- **Names are stored case-folded to uppercase** (the dir overlay runs each
  byte through its `up()`, which also folds lowercase PETSCII $C1-$DA):
  networked Meatloaf folders list lowercase-PETSCII names that the matcher's
  typed-input fold alone would never hit. Completion inserts the lowercase
  ASCII form -- the same thing the user would type by hand; truly
  case-sensitive URL segments remain the IEC layer's known limitation.
- **Fill**: `cache_name()` in the disk bank (it was the dir overlay) parses each drawn line's quoted
  name (skipping the header/disk title, the BLOCKS FREE trailer, and Meatloaf
  NFO pseudo-entries) and appends it; `cache_done()` sets the valid flag only
  on a clean end (no TIMEOUT/NODEV in ST). Both `ls` and `dir` fill; `pwd`
  does not touch the cache. A `q` quit mid-pagination validates the partial
  cache (same acceptable truncation as the size cap).
- **Invalidation** (valid flag cleared): the fs.c thunks of `cd`, `device`,
  `rm`, `mv`, `cp`; the SAVE KERNAL shim (kernal_stubs.s); a `load`/`fload`
  whose range overlaps the $CE00 page (it just overwrote the cache); a dir
  read that ends in a drive error (cache_done never validates); and boot
  (reset.s clears the flag -- the page is power-on garbage). The reader is
  defensive regardless: a length byte of 0 or >16 ends the scan.

## Code placement & budget

- **Resident** (src/complete.s, BASIC half `CODE` segment): word extraction,
  cache scan, common-prefix computation, insertion, and the candidate listing
  + prompt/line reprint. (as-built, v0.1.60) This is hand-written assembly:
  the first cut was C in shell.c and cc65 rendered it at ~1.3KB; the asm is
  ~600 bytes. ABI: readline passes the line length/cursor via $02B1/$02B2 and
  the shared `line` buffer; state lives at $02B3-$02BB and the zp walk
  pointers borrow $FB-$FE (free while readline runs). It sits in the BASIC
  half deliberately -- the KERNAL half is the scarcer resource.
- **Overlay** (dir.c): cache_reset/cache_name/cache_done around the ls/dir
  draw loops. Free ROM-wise (overlays live outside the 16KB); no mailbox
  needed since the cache page is fixed.
- **Thunks** (fs.c): clear the valid flag in the invalidating commands'
  thunks (one store each); irq.s carries the CTRL-tap emitter (~35 bytes,
  KERNAL half).

## Out of scope (v1)

- Path-segment completion (`games/pi<TAB>` — needs reading a non-CWD
  directory).
- Escaping embedded quotes in names (a name containing `"` itself).
- Command-name completion (deliberately removed earlier; unchanged).
- Per-command argument awareness: TAB completes filenames for any argument of
  any command (`poke 53<TAB>` just finds no match — harmless).

## Test plan

- Seed the cache directly (write the flag/count/entries at $CE00) and drive
  readline with injected keys — no drive needed for the
  matching/insertion/listing tests: unique match completes; common prefix
  stops at ambiguity; second TAB lists candidates and the line survives
  intact (screen rows + $D3/$D6 checks, like test_lineedit); TAB in the first
  word inert; empty cache inert; case-folded match.
- With the VICE disk attached and the dir overlay seeded: `ls` fills the
  cache (read it back from RAM); `rm`/`cd` clear the valid flag.
- Wrapped-line completion (insertion near col 40) reuses the existing
  lineedit wrap machinery — one test.
