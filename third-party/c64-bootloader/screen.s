; C64 code for text screen IO

; Copyright (C) 2026 Holger Gryska <r107sl@web.de>
; MIT License

.include        "c64.inc"

.import         popax, popa
.importzp       ptr1

.export        _printCxy, _printSxy, _drawFrame,  _clrScr, _waitVsync

PRINTL     := 32        ; maximum string length for printSxy

SCREEN_RAM := $0400
COLOR_RAM  := $d800

.segment "CODE"

; void printCxy (x, y, c);
_printCxy:
        pha             ; push character argument c on stack
        jsr popa        ; get y argument
        jsr calcAddr    ; calculate screen and color RAM addresses      
        jsr popa        ; get x argument
        tay
        pla             ; pop character from stack
        jsr ascii
        ora RVS         ; set revers bit
        sta (SCREEN_PTR),y
        lda CHARCOLOR   ; set color
        sta (CRAM_PTR),y
        rts

; void printSxy (x, y, *s);
_printSxy:
        sta ptr1        ; save string pointer (A/X)
        stx ptr1+1
        jsr popa        ; get y argument
        jsr calcAddr    ; calculate screen and color RAM addresses      
        jsr popa        ; get x argument
        tax             ; save x position in X
        clc
        adc SCREEN_PTR  ; add x position to screen RAM pointer
        sta SCREEN_PTR
        bcc @inc1
        inc SCREEN_PTR+1
@inc1:  txa             ; restore x position
        clc
        adc CRAM_PTR    ; add x position to color RAM pointer
        sta CRAM_PTR
        bcc @inc2
        inc CRAM_PTR+1
@inc2:  ldx #PRINTL     ; intitialize length counter
        ldy #$00        ; intitialize string index
@loop:  lda (ptr1),y    ; read string character
        beq @done       ; detect end of string 0
        jsr ascii
        ora RVS         ; set revers bit
        sta (SCREEN_PTR),y
        lda CHARCOLOR   ; set color
        sta (CRAM_PTR),y
        iny
        dex
        bne @loop
@done:  rts

; void drawFrame (void);
_drawFrame:
        lda #$00
        jsr calcAddr    ; calculate screen and color RAM addresses
        lda #$A0
        ldy #XSIZE-1
@loop1: sta (SCREEN_PTR),y
        dey
        bpl @loop1
        ldx #$01
@loop2: txa
        jsr calcAddr    ; calculate screen and color RAM addresses
        lda #$65
        ldy #$00
        sta (SCREEN_PTR),y
        lda #$6a
        ldy #XSIZE-1
        sta (SCREEN_PTR),y
        inx
        cpx #YSIZE-1
        bcc @loop2
        lda #YSIZE-1
        jsr calcAddr    ; calculate screen and color RAM addresses
        lda #$A0
        ldy #XSIZE-1
@loop3: sta (SCREEN_PTR),y
        dey
        bpl @loop3
        rts

; void clrScr (void);
_clrScr:
        ldx #$00      ; intitialize address index
@loop:
        lda #$20      ; load blank character
        sta SCREEN_RAM,x 
        sta SCREEN_RAM+$100,x
        sta SCREEN_RAM+$200,x
        sta SCREEN_RAM+$300,x
        lda CHARCOLOR ; load text color
        sta COLOR_RAM,x
        sta COLOR_RAM+$100,x
        sta COLOR_RAM+$200,x
        sta COLOR_RAM+$300,x
        inx            ; increase address index
        bne @loop
        rts

; void waitVsync (void);
_waitVsync:
        bit     VIC_CTRL1
        bpl     _waitVsync
@wait:
        bit     VIC_CTRL1
        bmi     @wait
        rts
		
; conversion of printable petscii code in A to screen code
petscii:
        cmp #$40
        bcc @end        ; control characters, numbers, punctuation marks
        cmp #$60
        bcc @sub64      ; upper or lower case
@sub128:and #$7f        ; graphical symbols or upper case
        rts
@sub64: and #$3f
@end:   rts

; conversion of printable ascii code in A to screen code
ascii:
        cmp #$41
        bcc @end        ; control characters, numbers, punctuation marks
        cmp #$5B
        bcc @upper
        cmp #$61
        bcc @end        ; control characters
        cmp #$7B
        bcs @end
        sec             ; lower case
        sbc #$60
        rts
@upper: sec             ; upper case
;        sbc #$40
@end:   rts

; calculate screen and color RAM addresses of line number in A
calcAddr:
        tay
        lda screen_low,y
        sta SCREEN_PTR
        sta CRAM_PTR
        lda screen_high,y
        sta SCREEN_PTR+1
        lda color_high,y
        sta CRAM_PTR+1
        rts

screen_low:  .byte $00,$28,$50,$78,$a0,$c8,$f0,$18,$40,$68,$90,$b8,$e0,$08,$30,$58,$80,$a8,$d0,$f8,$20,$48,$70,$98,$c0
screen_high: .byte $04,$04,$04,$04,$04,$04,$04,$05,$05,$05,$05,$05,$05,$06,$06,$06,$06,$06,$06,$06,$07,$07,$07,$07,$07
color_high:  .byte $d8,$d8,$d8,$d8,$d8,$d8,$d8,$d9,$d9,$d9,$d9,$d9,$d9,$da,$da,$da,$da,$da,$da,$da,$db,$db,$db,$db,$db
