; reset.s - Phase 0 reset routine.
;
; The minimal "is it alive?" boot: set up the stack, bring the VIC-II to a
; known text-display state (screen at $0400, ROM charset), clear the screen,
; paint HELLO, then halt. Just enough VIC init to make the screen visible;
; full hardware init (CIA, processor-port banking, banner) arrives in Phase 1.

.import irq_stub
.import nmi_stub

.export reset

; --- Hardware addresses --------------------------------------------------
SCREEN_RAM = $0400              ; default text screen (1000 cells)
COLOR_RAM  = $D800              ; per-cell color nybbles (1000 cells)

VIC_CTRL1  = $D011              ; control reg 1 (DEN, RSEL, YSCROLL, ...)
VIC_CTRL2  = $D016              ; control reg 2 (CSEL, XSCROLL, MCM)
VIC_MEMPTR = $D018              ; screen / charset base pointers
VIC_BORDER = $D020
VIC_BGCOL  = $D021

CIA2_PRA   = $DD00              ; VIC bank select (low 2 bits)
CIA2_DDRA  = $DD02

; --- Constants -----------------------------------------------------------
COLOR_BLACK = $00
COLOR_WHITE = $01
COLOR_BLUE  = $06

SPACE       = $20               ; screen code for a blank cell
CTRL1_ON    = $1B               ; DEN=1, RSEL=25 rows, text mode, YSCROLL=3
CTRL2_40COL = $C8               ; CSEL=40 cols
MEMPTR_0400 = $14               ; screen @ $0400, charset @ $1000 (char ROM)

.segment "CODE"

reset:
        sei                     ; mask interrupts during setup
        cld                     ; 6502 binary arithmetic
        ldx #$ff
        txs                     ; reset the hardware stack pointer

        ; --- VIC-II memory layout (display still disabled: $D011 = $00) ---
        lda #MEMPTR_0400
        sta VIC_MEMPTR          ; screen @ $0400, charset from char ROM
        lda #CTRL2_40COL
        sta VIC_CTRL2

        ; Select VIC bank 0 ($0000-$3FFF) so the char ROM shows at $1000.
        lda CIA2_DDRA
        ora #$03
        sta CIA2_DDRA           ; bank-select bits are outputs
        lda CIA2_PRA
        ora #$03                ; %......11 -> bank 0
        sta CIA2_PRA

        lda #COLOR_BLACK
        sta VIC_BORDER          ; border -> black
        lda #COLOR_BLUE
        sta VIC_BGCOL           ; background -> blue

        ; --- clear all 1000 screen cells to spaces, all color cells white ---
        ldx #$00
        lda #SPACE
@clrscr:
        sta SCREEN_RAM + $000,x
        sta SCREEN_RAM + $100,x
        sta SCREEN_RAM + $200,x
        sta SCREEN_RAM + $2E8,x ; tail: covers up to $07E7
        inx
        bne @clrscr

        ldx #$00
        lda #COLOR_WHITE
@clrcol:
        sta COLOR_RAM + $000,x
        sta COLOR_RAM + $100,x
        sta COLOR_RAM + $200,x
        sta COLOR_RAM + $2E8,x
        inx
        bne @clrcol

        ; --- paint HELLO at the top-left (white on blue) ---
        ldx #$00
@paint:
        lda hello,x
        sta SCREEN_RAM,x
        inx
        cpx #hello_len
        bne @paint

        ; Everything is ready: enable the display last to avoid a garbage flash.
        lda #CTRL1_ON
        sta VIC_CTRL1

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
