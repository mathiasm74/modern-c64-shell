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

.import rbcp_reset
.import rbcp_cmd_enter_cmd_resp
.import rbcp_cmd_load_slot
.import rbcp_cmd_switch_and_exit

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

        ; Copy __RBCP_CODE_SIZE__ bytes from __RBCP_CODE_LOAD__ to
        ; __RBCP_CODE_RUN__ (which puts the library + trampoline in place).
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
        ; Jump into the in-RAM trampoline. From here on we never come back
        ; to ROM-side code (rbcp_trampoline ends in a JMP through (FFFC)).
        jmp rbcp_trampoline

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

        ; --- Settle before reading the reset vector ----------------------
        ; Defensive spin before JMP (FFFC). Without a cartridge the swap is
        ; reliable (runstock / C=), so this is a no-op there. It was added while
        ; chasing the cart-present flakiness (shell boots + swaps, then ~80% of
        ; boots go black) on a hunch the JMP raced a half-finished switch -- but
        ; lengthening/adding the spin did NOT change the ~2/10 success rate, so
        ; the cart failure is electrical (the cart loading the bus garbles the
        ; RBCP swap reads), not a settle race. Kept as cheap insurance; the real
        ; fix is `onerom control select` (USB slot switch, not yet supported on
        ; fw 0.6.13) or booting stock directly. See the cart note in reset.s.
        ldx #$00
        ldy #$14
@settle:
        dex
        bne @settle
        dey
        bne @settle

        ; Hand off through the stock-KERNAL reset vector. Without this the
        ; system runs with stock ROMs mapped but with *our* state still
        ; resident -- $D018 still on the lowercase charset, our IRQ vector,
        ; an uncleared screen, etc -- and any JMP into a user program
        ; executes against that half-initialized environment (and produces
        ; the scattered $A0 artifacts we saw on first hardware test). Going
        ; through (FFFC) makes stock KERNAL do its IOINIT/RAMTAS/CINT,
        ; reset the VIC, clear the screen, and land at the READY prompt.
        ; A loaded program in RAM survives (RAM isn't cleared by the reset),
        ; so `RUN` from BASIC after the prompt picks it up.
        ;
        ; The patched-entry mechanism in _rbcp_launch_stock is retained for
        ; future use (a planted CBM80 stub at $8000 that the stock reset
        ; would autostart) but currently goes through this fallback instead.
        jmp ($FFFC)
