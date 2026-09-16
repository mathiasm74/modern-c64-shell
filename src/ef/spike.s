; ============================================================================
; spike.s -- EasyFlash proof of mechanism (PLAN.md section 7, phase 1).
;
; NOT Tardis. This is the gate: it proves the four things the whole EF port
; rests on, and nothing else in the plan is worth starting until it passes on
; real hardware.
;
;   1. BOOT      the cart supplies the reset vector from Ultimax, so Tardis
;                would still boot straight into the shell.
;   2. BANK      a write to $DE00 changes what is visible at $A000 -- this is
;                what replaces SWITCH_SLOT, at three cycles instead of ~588 us.
;   3. KILL      a write to $DE02 (MXG=100) turns the cartridge ROM off, leaving
;                a plain C64 -- this is what replaces the whole CBM80-and-reset
;                handover in `run`/`basic`.
;   4. RETURN    with the ROM off, the registers still answer, so software can
;                switch back -- this is what replaces the RBCP swap-back.
;
; (4) is the one that decides the port. The spec and VICE both say the I/O space
; keeps responding with the ROM off, but emulating enough to run EF game images
; is a lower bar than the full register behaviour, so KFF/Ultimate have to be
; asked directly.
;
; Layout, per skoe's Application Support: bank 0's ROMH carries the start-up
; code, which runs from $E000 in Ultimax straight after reset.
;
;   ROML bank 0  -> $8000   CBM80 signature + the spike itself
;   ROMH bank 0  -> $E000   (Ultimax) start-up and vectors; also seen at $A000
;                           in 16K mode, where its marker reads "bank 0"
;   ROMH bank 1  -> $A000   marker only, reads "bank 1"
; ============================================================================

EF_BANK  = $DE00                ; write-only: which 16K bank is visible
EF_CTRL  = $DE02                ; write-only: LED + MXG memory configuration
EF_RAM   = $DF00                ; 256 bytes, "always visible" -- and still there
                                ; with the ROM off, which is why the kill and
                                ; return helpers must live here

MODE_16K = $87                  ; LED on, MXG=111: ROML $8000 + ROMH $A000
MODE_OFF = $04                  ; LED off, MXG=100: cartridge ROM off

CHROUT   = $FFD2
GETIN    = $FFE4
IOINIT   = $FF84
RAMTAS   = $FF87
RESTOR   = $FF8A
CINT     = $FF81
STOCK_RESET = $FCE2

; ---------------------------------------------------------------------------
        .segment "ROML0"        ; -> $8000, always mapped in 16K mode
; ---------------------------------------------------------------------------
        .word cold              ; $8000 CBM80 cold start
        .word cold              ; $8002 warm start
        .byte $C3, $C2, $CD, $38, $30   ; "CBM80"

cold:
        sei
        cld
        ldx #$FF
        txs
        ; The stock reset checks for the cartridge BEFORE it initialises
        ; anything ($FCE7 jsr $FD02, then jmp ($8000)), so the KERNAL is not set
        ; up yet -- do it here, exactly as run_stub does after the One ROM swap.
        jsr IOINIT
        jsr RAMTAS
        jsr RESTOR
        jsr CINT
        cli

        lda #<msg_title
        ldy #>msg_title
        jsr puts

        ; --- (2) banking: read the ROMH marker, switch bank, read it again ---
        lda #$00
        sta EF_BANK
        lda #<msg_b0
        ldy #>msg_b0
        jsr puts
        jsr show_marker

        lda #$01
        sta EF_BANK
        lda #<msg_b1
        ldy #>msg_b1
        jsr puts
        jsr show_marker

        lda #$00                ; back to bank 0
        sta EF_BANK

        ; --- install the kill/return helpers into the cartridge's own RAM ----
        ldx #$00
@copy:  lda helpers,x
        sta EF_RAM,x
        inx
        cpx #(helpers_end - helpers)
        bne @copy

        lda #<msg_keys
        ldy #>msg_keys
        jsr puts
@wait:  jsr GETIN
        cmp #$4B                ; "K"
        bne @wait
        jmp EF_RAM              ; (3) kill -- runs from RAM, since $8000 is
                                ;     about to stop existing

; Print the five bytes at $A000, whichever bank is mapped there.
show_marker:
        ldy #$00
@l:     lda $A000,y
        jsr CHROUT
        iny
        cpy #$06
        bne @l
        lda #$0D
        jmp CHROUT

; A zero-page pointer, NOT self-modifying code: this runs from ROM, where a
; store to the operand goes to the RAM underneath and the read still comes from
; the ROM -- so the first version printed whatever was at $FFFF and filled the
; screen with garbage. Worth remembering for the port: everything that was
; resident in the KERNAL half is moving into cartridge ROM, where the same trap
; applies.
PTR = $FB
puts:   sta PTR
        sty PTR+1
        ldy #$00
@p:     lda (PTR),y
        beq @done
        jsr CHROUT
        iny
        bne @p
@done:  rts

; ---------------------------------------------------------------------------
; The helpers, assembled here but COPIED to $DF00 and run from there. They must
; not live in ROM: the kill routine's next instruction after the $DE02 write
; would otherwise be fetched from a window that has just disappeared.
; ---------------------------------------------------------------------------
helpers:
        ; --- $DF00: kill the cartridge, land in stock BASIC ---
        lda #MODE_OFF
        sta EF_CTRL             ; from here on $8000-$BFFF is plain RAM
        lda #$00
        sta $8004               ; scrub the CBM80 signature's RAM shadow, so the
                                ; stock reset does not see a phantom cartridge
        jmp STOCK_RESET
        ; pad so the return helper lands on a round address the user can SYS to
        .res $20 - (* - helpers), $EA
        ; --- $DF20: switch back on and cold-start the cart ---
        lda #MODE_16K
        sta EF_CTRL
        jmp STOCK_RESET         ; finds the CBM80 again, enters `cold`
helpers_end:

msg_title:
        .byte $93, $0E          ; clear, lowercase charset
        .byte "tardis easyflash spike", $0D, $0D, $00
msg_b0: .byte "bank 0 at $a000: ", $00
msg_b1: .byte "bank 1 at $a000: ", $00
msg_keys:
        .byte $0D, "k = kill cart, drop to basic.", $0D
        .byte "from basic: sys 57120 to come back.", $0D, $00

; ---------------------------------------------------------------------------
        .segment "ROMH0"        ; bank 0 ROMH: $E000 in Ultimax, $A000 in 16K
; ---------------------------------------------------------------------------
        .byte "bank 0"          ; the marker read at $A000 in 16K mode

; ---------------------------------------------------------------------------
        .segment "ROMH0_BOOT"   ; the tail of bank 0's ROMH: $FF00-$FFFF
; ---------------------------------------------------------------------------
; Runs in ULTIMAX straight after reset, so almost nothing is mapped: no RAM
; above $0FFF, no stock ROMs. All it does is establish a sane CPU state, switch
; to 16K -- which brings the stock KERNAL back at $E000 and our ROML at $8000 --
; and hand over to the stock reset, which finds our CBM80 and enters `cold`.
boot:
        sei
        cld
        ldx #$FF
        txs
        lda #$37                ; $01 before $00, per the EF start-up notes
        sta $01
        lda #$2F
        sta $00

        ; THE SWITCH CANNOT HAPPEN FROM HERE. This code runs at $FF00 out of our
        ; ROMH because Ultimax puts it at $E000-$FFFF -- and the instant $DE02
        ; selects 16K, our ROMH moves to $A000 and $E000-$FFFF becomes the STOCK
        ; KERNAL. The next instruction would be fetched from whatever stock byte
        ; happens to live at this address. (Exactly why bank_call lives in the
        ; One ROM build's static half, and why the kill helper lives in the
        ; cartridge's $DF00 RAM.)
        ;
        ; So copy the switch into RAM and run it there. Ultimax leaves
        ; $0000-$0FFF as RAM, which is enough.
        ldx #(switch_end - switch - 1)
@cp:    lda switch,x
        sta $0200,x
        dex
        bpl @cp
        jmp $0200

switch:
        lda #MODE_16K
        sta EF_CTRL             ; from the next fetch on, we are in 16K: our
                                ; ROML is at $8000 and the stock KERNAL is back
        jmp STOCK_RESET         ; which finds our CBM80 and enters `cold`
switch_end:

; ---------------------------------------------------------------------------
        .segment "ROMH0_VEC"    ; $FFFA-$FFFF -- its own segment because ca65
                                ; cannot compute padding to a fixed address in a
                                ; segment ld65 places
; ---------------------------------------------------------------------------
        .word boot              ; $FFFA NMI
        .word boot              ; $FFFC RESET
        .word boot              ; $FFFE IRQ

; ---------------------------------------------------------------------------
        .segment "ROMH1"        ; bank 1 ROMH -> $A000 in 16K mode
; ---------------------------------------------------------------------------
        .byte "bank 1"
