; irq.s - Phase 3 interrupt handler and keyboard scan.
;
; CIA #1 timer A fires ~60 times a second. The handler acknowledges it,
; advances the jiffy clock, and scans the keyboard matrix, pushing decoded
; PETSCII into the keyboard buffer. NMI is still just an RTI stub.

.export irq_handler
.export nmi_stub

; --- CIA #1 -------------------------------------------------------------
CIA1_PRA  = $DC00       ; keyboard column select (output)
CIA1_PRB  = $DC01       ; keyboard row read (input)
CIA1_ICR  = $DC0D       ; reading acknowledges the timer interrupt

; --- jiffy clock and keyboard state (KERNAL-compatible) -----------------
TIME      = $A0         ; $A0/$A1/$A2: 24-bit jiffy counter
LSTX      = $C5         ; matrix code of the last key seen ($FF = none)
NDX       = $C6         ; number of characters in the keyboard buffer
KEYBUF    = $0277       ; keyboard buffer, 10 bytes
KEYBUF_MAX = 10

COLMASK   = $F7         ; scan scratch (not used by the main thread / CHROUT)
ROWBITS   = $F8
found_key = $F9         ; matrix code found this scan ($FF = none)

; Hand-written core lives in the KERNAL ROM ($E000); the cc65-emitted shell
; owns the default CODE segment in the BASIC ROM ($A000). See cfg/rom.cfg.
.segment "KCODE"

; -------------------------------------------------------------------------
; irq_handler - timer tick: ack, advance jiffy clock, scan keyboard.
; -------------------------------------------------------------------------
irq_handler:
        pha
        txa
        pha
        tya
        pha

        lda CIA1_ICR            ; acknowledge CIA #1 (clears the IRQ line)

        inc TIME+2              ; advance the 24-bit jiffy clock
        bne @scan
        inc TIME+1
        bne @scan
        inc TIME
@scan:
        jsr scan_keyboard

        pla
        tay
        pla
        tax
        pla
        rti

nmi_stub:
        rti

; -------------------------------------------------------------------------
; scan_keyboard - walk the 8x8 matrix, decode one pressed key to PETSCII,
; and push it into the keyboard buffer. Simple debounce: a key is emitted
; once when first pressed (no auto-repeat); shift keys are skipped.
; -------------------------------------------------------------------------
scan_keyboard:
        lda #$FF
        sta found_key           ; assume nothing pressed
        ldx #$00                ; matrix code 0..63
        lda #$FE                ; walking-zero column select, starting PA0
        sta COLMASK
@col:
        lda COLMASK
        sta CIA1_PRA            ; drive one column low
        lda CIA1_PRB            ; read the 8 rows (0 = pressed)
        sta ROWBITS
        ldy #$08
@row:
        lsr ROWBITS             ; next row bit -> carry
        bcs @next               ; 1 = not pressed
        cpx #15
        beq @next               ; left shift  - skip
        cpx #52
        beq @next               ; right shift - skip
        stx found_key           ; remember this key (last pressed wins)
@next:
        inx
        dey
        bne @row
        sec
        rol COLMASK             ; rotate the 0 to the next column (brings in 1)
        cpx #64
        bcc @col

        ldx found_key
        cpx #$FF
        beq @none               ; nothing pressed this scan
        cpx LSTX
        beq @ret                ; same key still held -> no repeat
        stx LSTX                ; new key
        lda keytab,x
        beq @ret                ; non-emitting key (ctrl, cbm, ...)
        ldx NDX
        cpx #KEYBUF_MAX
        bcs @ret                ; buffer full
        sta KEYBUF,x
        inc NDX
        rts
@none:
        lda #$FF
        sta LSTX                ; released -> next press will register
@ret:
        rts

; -------------------------------------------------------------------------
; keytab - matrix code (0-63) -> PETSCII. $00 = key produces no character.
; Standard C64 matrix order; unshifted only (shifted symbols come later).
; -------------------------------------------------------------------------
keytab:
        .byte $14,$0D,$1D,$88,$85,$86,$87,$11   ; DEL RET CR> F7 F1 F3 F5 CR\/
        .byte $33,$57,$41,$34,$5A,$53,$45,$00   ; 3 W A 4 Z S E LSHIFT
        .byte $35,$52,$44,$36,$43,$46,$54,$58   ; 5 R D 6 C F T X
        .byte $37,$59,$47,$38,$42,$48,$55,$56   ; 7 Y G 8 B H U V
        .byte $39,$49,$4A,$30,$4D,$4B,$4F,$4E   ; 9 I J 0 M K O N
        .byte $2B,$50,$4C,$2D,$2E,$3A,$40,$2C   ; + P L - . : @ ,
        .byte $5C,$2A,$3B,$13,$00,$3D,$5E,$2F   ; POUND * ; HOME RSHIFT = ^ /
        .byte $31,$5F,$00,$32,$20,$00,$51,$03   ; 1 <- CTRL 2 SPACE CBM Q STOP
