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
.export rbcp_trampoline_jmp           ; "

.import rbcp_reset
.import rbcp_cmd_enter_cmd_resp
.import rbcp_cmd_load_slot
.import rbcp_cmd_switch_and_exit

; Where the library sits in ROM (load) and runs (run); both defined by ld65
; when the RBCP_CODE segment has `define = yes`.
.import __RBCP_CODE_LOAD__
.import __RBCP_CODE_RUN__
.import __RBCP_CODE_SIZE__

; Stock ROMs live in flash slot 3 of cfg/onerom-stock.json (the 4th
; chip_set: system/usb, host-control, shell, stock). We load that into a
; RAM slot the device isn't currently serving and then switch to it.
; The exact safe RAM slot to use is device-dependent; slot 1 is the
; reference's choice in the bootloader example, and a reasonable guess
; until hardware testing tells us otherwise.
RBCP_STOCK_FLASH_SLOT = 3
RBCP_STOCK_RAM_SLOT   = 1

; Scratch in the gap above iec.s's $A9 SECADR and below the KERNAL's $B7
; FNLEN. Used only inside _rbcp_launch_stock (which never returns).
copy_src = $AB
copy_dst = $AD
copy_len = $AF
entry_lo = $B1
entry_hi = $B2

; =========================================================================
; ROM-side stub. Runs from KERNAL ROM ($Exxx); copies the RBCP code into RAM
; and hands off. Never returns.
; =========================================================================
.segment "KCODE"

_rbcp_launch_stock:
        ; cc65 fastcall: A=entry_lo, X=entry_hi. Stash for after the copy --
        ; we can't patch the trampoline yet because the copy overwrites it.
        sta entry_lo
        stx entry_hi

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
        ; Now patch the trampoline's "JMP $0000" operand with the stashed
        ; entry address. The trampoline is in RAM now; STAing into its
        ; operand bytes is harmless and survives until we JMP there.
        lda entry_lo
        sta rbcp_trampoline_jmp + 1
        lda entry_hi
        sta rbcp_trampoline_jmp + 2

        ; Jump into the in-RAM trampoline. From here on we never come back
        ; to ROM-side code (rbcp_trampoline ends in a JMP, not RTS).
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
rbcp_trampoline_jmp:
        jmp $0000                       ; entry address; operand byte+1/+2
                                        ; patched by _rbcp_launch_stock above
