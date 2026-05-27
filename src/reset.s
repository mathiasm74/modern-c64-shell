; reset.s - Phase 0 reset routine.
;
; The minimal "is it alive?" boot: set up the stack, paint the border and
; background, write HELLO to screen RAM, then halt. No I/O, no interrupts.
; Proper hardware init (VIC-II, CIA, processor-port banking) arrives in Phase 1.

.import irq_stub
.import nmi_stub

.export reset

; --- Hardware addresses --------------------------------------------------
SCREEN_RAM = $0400              ; default text screen
COLOR_RAM  = $D800              ; per-cell color nybbles
VIC_BORDER = $D020
VIC_BGCOL  = $D021

; --- Color constants -----------------------------------------------------
COLOR_BLACK = $00
COLOR_WHITE = $01
COLOR_BLUE  = $06

.segment "CODE"

reset:
        sei                     ; mask interrupts during setup
        cld                     ; 6502 binary arithmetic
        ldx #$ff
        txs                     ; reset the hardware stack pointer

        lda #COLOR_BLACK
        sta VIC_BORDER          ; border  -> black
        lda #COLOR_BLUE
        sta VIC_BGCOL           ; screen  -> blue

        ; Copy HELLO into the top-left of the screen, white on blue.
        ldx #$00
@paint:
        lda hello,x
        sta SCREEN_RAM,x
        lda #COLOR_WHITE
        sta COLOR_RAM,x
        inx
        cpx #hello_len
        bne @paint

@halt:
        jmp @halt               ; nothing else to do yet

; "HELLO" in C64 screen codes ('A'=1 ... so H=8, E=5, L=12, O=15).
hello:
        .byte 8, 5, 12, 12, 15
hello_len = * - hello

; --- 6502 hardware vectors ($FFFA-$FFFF) ---------------------------------
.segment "VECTORS"
        .addr nmi_stub          ; $FFFA NMI
        .addr reset             ; $FFFC RESET
        .addr irq_stub          ; $FFFE IRQ/BRK
