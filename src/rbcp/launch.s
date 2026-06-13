; launch.s - RBCP bank-swap launcher.
;
; cmd_runstock calls _rbcp_launch_stock(entry). The flow:
;   1. ROM-side stub copies the whole RBCP_CODE block from KERNAL ROM into
;      RBCP_RAM at $C800, where it's linked to *run* -- this places the
;      library and the in-RAM trampoline at the addresses their internal
;      JSR/JMP/STAs were resolved to.
;   2. Patches the trampoline's final JMP operand with the program's entry.
;   3. JMP into the in-RAM trampoline.
; The trampoline (in RBCP_CODE so it's a part of the copy) then does:
;   SEI -> rbcp_reset -> enter_cmd_resp -> load_slot -> switch_and_exit
; and finally JMPs to the patched entry. After switch_and_exit the device is
; serving the stock-ROM slot; the JMP lands in the program's territory under
; the new ROM map.
;
; This file deliberately uses no cc65 runtime: no software stack, no zero-page
; pseudo-regs that might collide with the library's $80-$8F block.

.export _rbcp_launch_stock
.export rbcp_trampoline               ; exported for tests / inspection only

.include "rbcp_defs.s"          ; constants only (ZP/arg locations, addresses)

.import rbcp_reset
.import rbcp_cmd_enter_cmd_resp
.import rbcp_cmd_load_slot
.import rbcp_cmd_switch_and_exit
.import rbcp_cmd_slot_peek
.import rbcp_cmd_exit_cmd_resp

; Where the library sits in ROM (load) and runs (run); both defined by ld65
; when the RBCP_CODE segment has `define = yes`.
.import __RBCP_CODE_LOAD__
.import __RBCP_CODE_RUN__
.import __RBCP_CODE_SIZE__

; Stock ROMs are the 4th chip_set in cfg/onerom-stock.json (system/usb,
; host-control, shell, stock) -- but RBCP indexes by loadable ROM SET, not
; raw slot: `onerom inspect info` reports rom_set_count = 2 (shell=0,
; stock=1), so the plugin slots don't count. The stock ROM set is flash
; slot 1, NOT 3 (3 is out of range -> loads garbage -> black screen). We
; load it into a RAM slot the device isn't serving and switch to it.
RBCP_STOCK_FLASH_SLOT = 1
RBCP_STOCK_RAM_SLOT   = 1

; Scratch in the gap above iec.s's $A9 SECADR and below the KERNAL's $B7
; FNLEN. Used only inside _rbcp_launch_stock (which never returns).
copy_src = $AB
copy_dst = $AD
copy_len = $AF

; =========================================================================
; ROM-side stub. Runs from KERNAL ROM ($Exxx); copies the RBCP code into RAM
; and hands off. Never returns.
; =========================================================================
.segment "KCODE"

_rbcp_launch_stock:
        ; No arguments. The trampoline hands off through (FFFC) -- the stock
        ; KERNAL reset vector -- so there's nothing to patch on the way in.
        ; Once we want a planted-CBM80-style autostart, we'll bring back an
        ; entry argument and patch a JMP in the trampoline.

        ; --- Quiet our IRQ source before swapping ------------------------
        ; If we're swapping from the running shell (the late cartridge-detect
        ; path, or runstock) our CIA1 timer-A IRQ is live. On a real cartridge
        ; boot no timer runs, and the stock KERNAL's cartridge path (JMP $8000)
        ; skips IOINIT, so nothing would stop ours: the first IRQ after the
        ; game's CLI goes through stock's $FF48 -> JMP ($0314) -> uninitialized
        ; RAM. Stop both CIAs' timers and clear pending flags to restore the
        ; real-cart-boot invariant (no IRQ until the game arms its own).
        ; (Harmless on the early C= path, where the timers are already stopped,
        ; and on runstock, where stock's BASIC reset re-inits the CIAs anyway.)
        ;
        ; Note: the game-start flakiness this was added for turned out to be a
        ; Meatloaf on the IEC bus (see the postmortem note in reset.s); this
        ; cleanup is kept because it's correct, not because it was the fix.
        sei
        lda #$7f
        sta $DC0D               ; CIA1 ICR: disable all interrupt sources
        sta $DD0D               ; CIA2 ICR
        lda $DC0D               ; read to clear any pending flags
        lda $DD0D
        lda #$00
        sta $DC0E               ; stop CIA1 timer A
        sta $DC0F               ; stop CIA1 timer B
        sta $DD0E               ; stop CIA2 timer A
        sta $DD0F               ; stop CIA2 timer B

        jsr rbcp_copy_to_ram

        ; Jump into the in-RAM trampoline. From here on we never come back
        ; to ROM-side code (rbcp_trampoline ends in a JMP through (FFFC)).
        jmp rbcp_trampoline

; -------------------------------------------------------------------------
; rbcp_copy_to_ram - copy __RBCP_CODE_SIZE__ bytes from __RBCP_CODE_LOAD__
; (KERNAL ROM) to __RBCP_CODE_RUN__ (RAM), putting the library + trampolines
; at the addresses their internal references were linked for. Idempotent;
; clobbers A/Y and the copy_* zero-page scratch.
; -------------------------------------------------------------------------
rbcp_copy_to_ram:
        lda #<__RBCP_CODE_LOAD__
        sta copy_src
        lda #>__RBCP_CODE_LOAD__
        sta copy_src+1
        lda #<__RBCP_CODE_RUN__
        sta copy_dst
        lda #>__RBCP_CODE_RUN__
        sta copy_dst+1
        lda #<__RBCP_CODE_SIZE__
        sta copy_len
        lda #>__RBCP_CODE_SIZE__
        sta copy_len+1
@copy:
        lda copy_len
        ora copy_len+1
        beq @done
        ldy #0
        lda (copy_src),y
        sta (copy_dst),y
        inc copy_src
        bne :+
        inc copy_src+1
:       inc copy_dst
        bne :+
        inc copy_dst+1
:       lda copy_len
        bne :+
        dec copy_len+1
:       dec copy_len
        jmp @copy
@done:
        rts

; -------------------------------------------------------------------------
; _overlay_fetch_page - tardis overlay loader (C-callable, fastcall:
; A = overlay page number). Fetches one 256-byte page from the overlays
; flash set into the overlay cache at $CE00: enter command-response mode,
; LOAD_SLOT the overlays flash set into RAM slot 1, SLOT_PEEK page*256 into
; the back-channel window, copy the 256 bytes to the cache, exit. Returns
; A: 0 = ok, 1 = enter failed, 2 = load failed, 3 = peek failed,
; 4 = exit failed. Same RAM-copy discipline as the PoC (see _rbcp_poc_peek).
;
; LOAD_SLOT on every fetch is deliberate first-pass simplicity: it also
; repairs RAM slot 1 after a runstock/cart swap clobbered it with the stock
; ROMs, at the cost of an in-device 8KB copy (~ms) per cache miss.
; -------------------------------------------------------------------------
.export _overlay_fetch_page
_overlay_fetch_page:
        jsr rbcp_copy_to_ram
        jmp rbcp_ovl_tramp      ; rts there returns to our caller

; -------------------------------------------------------------------------
; _overlay_fetch_multi - fetch N consecutive overlay pages to an arbitrary
; RAM destination, one RBCP session for the whole run. Parameters go in the
; page-2 mailbox (it must be RAM the library copy doesn't overwrite, and the
; caller sets it BEFORE this is called):
;   OVL_MB_PAGE ($02C0) first overlay page,
;   OVL_MB_CNT  ($02C1) page count (>= 1),
;   OVL_MB_DST  ($02C2) destination page (hi byte; lo is always $00).
; The mailbox is consumed (PAGE/DST step per page, CNT counts down).
; Returns A: 0 = ok, 1 = enter failed, 2 = load failed, 3 = peek failed,
; 4 = exit failed.
; -------------------------------------------------------------------------
.export _overlay_fetch_multi
_overlay_fetch_multi:
        jsr rbcp_copy_to_ram
        jmp rbcp_ovlm_tramp     ; rts there returns to our caller

; =========================================================================
; RAM-side trampoline. Linked into RBCP_CODE so it lives alongside the
; library; after _rbcp_launch_stock's copy it sits in RAM, where it can
; survive the bank swap.
; =========================================================================
.segment "RBCP_CODE"

rbcp_trampoline:
        sei                             ; IRQs would fetch from $E0xx, which
                                        ; is our command page in CR mode -- a
                                        ; spurious read there sends a stray
                                        ; command. Stay masked from now on.
        jsr rbcp_reset                  ; reset the device's protocol state
        jsr rbcp_cmd_enter_cmd_resp     ; enter command-respond mode (the
                                        ; "knock" + handshake)
        lda #RBCP_STOCK_RAM_SLOT
        ldx #RBCP_STOCK_FLASH_SLOT
        jsr rbcp_cmd_load_slot          ; flash slot -> RAM slot
        lda #RBCP_STOCK_RAM_SLOT
        jsr rbcp_cmd_switch_and_exit    ; activate it; the device begins
                                        ; serving the new slot immediately
                                        ; (no polling per the protocol spec)

        ; Hand off through the stock-KERNAL reset vector. For a cart this lands
        ; in the CBM80 cold-start (stock reset's JMP ($8000)); with no cart it
        ; runs the full stock init and reaches READY. A loaded program in RAM
        ; survives the reset, so RUN from BASIC picks it up. (Going through
        ; (FFFC) -- rather than into a half-initialized environment -- is also
        ; what cleared the scattered $A0 artifacts seen on first hardware test.)
        ;
        ; NOTE: a RESTOR ($FF8A) call was tried here to fix the cart path's
        ; skipped RAM vectors and didn't help (the flakiness it targeted was
        ; later traced to a Meatloaf on the IEC bus -- see reset.s). It was
        ; dropped again: real carts boot with uninitialized vectors anyway, so
        ; they can't rely on them, and keeping the handoff a single JMP avoids
        ; executing stock ROM code before the game expects it.
        jmp ($FFFC)

; -------------------------------------------------------------------------
; rbcp_ovl_tramp - RAM side of _overlay_fetch_page. The 256-byte copy out
; of the back-channel window happens while still in command-response mode
; (back-channel reads are ordinary served-ROM reads, the same thing the
; library's own polling does); only command-page fetches are off limits,
; and this runs from the RAM copy.
; -------------------------------------------------------------------------
OVERLAY_CACHE  = $CE00          ; free RAM above the RBCP_RAM region
OVL_FLASH_SET  = 2              ; loadable ROM-set index: shell=0, stock=1,
                                ; overlays=2 (cfg/onerom-stock.json order;
                                ; plugins don't count)
OVL_RAM_SLOT   = 1              ; staging slot (shared with the stock swap)

rbcp_ovl_tramp:
        sta ovl_page            ; fastcall A = page number
        sei
        jsr rbcp_reset
        jsr rbcp_cmd_enter_cmd_resp
        bcs @enter_fail
        lda #OVL_RAM_SLOT
        ldx #OVL_FLASH_SET
        jsr rbcp_cmd_load_slot
        bcs @load_fail
        lda #0
        sta rbcp_arg1           ; offset lo = 0 (pages are 256-aligned)
        sta rbcp_arg3           ; offset hi
        lda ovl_page
        sta rbcp_arg2           ; offset mid = page number
        lda #0                  ; count 0 = 256 bytes
        ldx #OVL_RAM_SLOT
        jsr rbcp_cmd_slot_peek
        bcs @peek_fail
        ldy #0
@copy:
        lda RBCP_DATA_ADDR,y
        sta OVERLAY_CACHE,y
        iny
        bne @copy
        jsr rbcp_cmd_exit_cmd_resp
        bcs @exit_fail
        cli
        lda #0
        ldx #0
        rts
@enter_fail:
        cli
        lda #1
        ldx #0
        rts
@load_fail:
        jsr rbcp_cmd_exit_cmd_resp      ; best effort: leave CR mode
        cli
        lda #2
        ldx #0
        rts
@peek_fail:
        jsr rbcp_cmd_exit_cmd_resp
        cli
        lda #3
        ldx #0
        rts
@exit_fail:
        cli
        lda #4
        ldx #0
        rts

ovl_page: .byte 0               ; written at the RAM run address

; -------------------------------------------------------------------------
; rbcp_ovlm_tramp - RAM side of _overlay_fetch_multi: one session, looping
; SLOT_PEEK + copy per page. The destination store's hi byte is patched per
; page -- this code runs from RAM, so self-modification is fine.
; -------------------------------------------------------------------------
OVL_MB_PAGE = $02C0
OVL_MB_CNT  = $02C1
OVL_MB_DST  = $02C2

rbcp_ovlm_tramp:
        sei
        jsr rbcp_reset
        jsr rbcp_cmd_enter_cmd_resp
        bcs @enter_fail
        lda #OVL_RAM_SLOT
        ldx #OVL_FLASH_SET
        jsr rbcp_cmd_load_slot
        bcs @load_fail
@page:
        lda #0
        sta rbcp_arg1           ; offset lo (pages are 256-aligned)
        sta rbcp_arg3           ; offset hi
        lda OVL_MB_PAGE
        sta rbcp_arg2           ; offset mid = page number
        lda #0                  ; count 0 = 256 bytes
        ldx #OVL_RAM_SLOT
        jsr rbcp_cmd_slot_peek
        bcs @peek_fail
        lda OVL_MB_DST
        sta @dst+2              ; patch the store's hi byte (RAM code)
        ldy #0
@cp:
        lda RBCP_DATA_ADDR,y
@dst:   sta $FF00,y             ; hi byte patched above
        iny
        bne @cp
        inc OVL_MB_PAGE
        inc OVL_MB_DST
        dec OVL_MB_CNT
        bne @page
        jsr rbcp_cmd_exit_cmd_resp
        bcs @exit_fail
        cli
        lda #0
        ldx #0
        rts
@enter_fail:
        cli
        lda #1
        ldx #0
        rts
@load_fail:
        jsr rbcp_cmd_exit_cmd_resp      ; best effort: leave CR mode
        cli
        lda #2
        ldx #0
        rts
@peek_fail:
        jsr rbcp_cmd_exit_cmd_resp
        cli
        lda #3
        ldx #0
        rts
@exit_fail:
        cli
        lda #4
        ldx #0
        rts
