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
; _rbcp_poc_peek - tardis proof-of-concept (C-callable; see cmd_tardis).
; Knock/enter command-response mode, SLOT_PEEK 64 bytes from RAM slot 0
; (the active slot, i.e. our own image) offset 0 into the back-channel
; window, exit command mode. The peeked bytes persist at RBCP_DATA_ADDR
; ($FA08) for the caller to inspect. Returns A: 0 = ok, 1 = enter failed,
; 2 = peek failed, 3 = exit failed (rbcp_zp_5 has the library's stage
; detail). Unlike the stock launch this returns to the caller, but it
; still runs the session from the RAM copy: in command-response mode every
; read of the $E0xx command page is command traffic, and KCODE starts at
; $E000, so ROM-side code must stay out of the conversation.
; -------------------------------------------------------------------------
.export _rbcp_poc_peek
_rbcp_poc_peek:
        jsr rbcp_copy_to_ram
        jmp rbcp_poc_tramp      ; rts there returns to our caller

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
; rbcp_poc_tramp - RAM side of _rbcp_poc_peek (see the KCODE stub above).
; Runs entirely from the RAM copy so no instruction fetch can stray into
; the $E0xx command page while the session is open. Returns to the C
; caller via rts (the KCODE stub jmp'd here, so the caller's return
; address is on top of the stack).
; -------------------------------------------------------------------------
rbcp_poc_tramp:
        sei                             ; no IRQ fetches during the session
        jsr rbcp_reset                  ; reset the device's protocol state
        jsr rbcp_cmd_enter_cmd_resp
        bcs @enter_fail

        ; SLOT_PEEK 64 bytes from RAM slot 0 (the active slot = our own
        ; image), source offset 0. enter_cmd_resp clobbered the arg block,
        ; so the offset bytes are set here, after it.
        lda #0
        sta rbcp_arg1                   ; offset lo
        sta rbcp_arg2                   ; offset mid
        sta rbcp_arg3                   ; offset hi
        lda #64                         ; count
        ldx #0                          ; source RAM slot
        jsr rbcp_cmd_slot_peek
        bcs @peek_fail

        jsr rbcp_cmd_exit_cmd_resp
        bcs @exit_fail
        cli
        lda #0                          ; ok; bytes are live at RBCP_DATA_ADDR
        ldx #0
        rts
@enter_fail:
        cli                             ; never entered CR mode; nothing to undo
        lda #1
        ldx #0
        rts
@peek_fail:
        jsr rbcp_cmd_exit_cmd_resp      ; best effort: don't strand the device
        cli                             ; in command-response mode
        lda #2
        ldx #0
        rts
@exit_fail:
        cli
        lda #3
        ldx #0
        rts
