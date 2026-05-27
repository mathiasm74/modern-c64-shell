; reset.s - Phase 1 boot: take full control of the machine.
;
; Bring the C64 to a clean, deterministic state under our own control instead
; of relying on stock KERNAL behavior: set the processor port memory map,
; quiet both CIAs (timers stopped, interrupts masked), initialize the VIC-II,
; clear the screen, and draw a startup banner. No interrupts are enabled and
; there is no keyboard input yet -- that arrives in Phase 3.

.import irq_stub
.import nmi_stub

.export reset

; --- Processor port ------------------------------------------------------
CPU_DDR    = $00
CPU_PORT   = $01

; --- Screen / color RAM --------------------------------------------------
SCREEN_RAM = $0400              ; 1000 text cells
COLOR_RAM  = $D800              ; 1000 color nybbles

; --- VIC-II --------------------------------------------------------------
VIC_CTRL1  = $D011              ; DEN, RSEL, YSCROLL, ...
VIC_CTRL2  = $D016              ; CSEL, XSCROLL, MCM
VIC_MEMPTR = $D018              ; screen / charset base
VIC_BORDER = $D020
VIC_BGCOL  = $D021

; --- CIA #1 ($DC00) and CIA #2 ($DD00) -----------------------------------
CIA1_ICR   = $DC0D              ; interrupt control/status
CIA1_CRA   = $DC0E              ; timer A control
CIA1_CRB   = $DC0F              ; timer B control
CIA2_PRA   = $DD00              ; port A (low 2 bits select VIC bank)
CIA2_DDRA  = $DD02
CIA2_ICR   = $DD0D
CIA2_CRA   = $DD0E
CIA2_CRB   = $DD0F

; --- Zero-page scratch (documented-free bytes; see CLAUDE.md) -------------
zp_src     = $FB                ; $FB/$FC: source pointer for puts_at
zp_dst     = $FD                ; $FD/$FE: screen destination pointer

; --- Constants -----------------------------------------------------------
COLOR_BLACK  = $00
COLOR_BLUE   = $06
COLOR_LTBLUE = $0E              ; classic C64 default text color
SPACE        = $20              ; screen code for a blank cell

CPU_DDR_STD  = $2F              ; port bits 0-5 are outputs
CPU_PORT_STD = $37              ; shell ROM ($A000) + KERNAL ROM ($E000) + I/O

CTRL1_BLANK  = $0B              ; 25 rows, text mode, display OFF
CTRL1_ON     = $1B              ; same, display ON
CTRL2_40COL  = $C8              ; 40 columns
MEMPTR_0400  = $14              ; screen @ $0400, charset @ $1000 (char ROM)

; Write a zero-terminated ASCII string `str` to screen address `dst`.
; The parentheses matter: ca65's #< / #> byte operators bind tighter than +,
; so `#>dst` without them would compute (>base)+offset, not >(base+offset).
.macro PRINT str, dst
        lda #<(str)
        sta zp_src
        lda #>(str)
        sta zp_src+1
        lda #<(dst)
        sta zp_dst
        lda #>(dst)
        sta zp_dst+1
        jsr puts_at
.endmacro

.segment "CODE"

reset:
        sei                     ; mask IRQs during setup
        cld                     ; binary arithmetic
        ldx #$ff
        txs                     ; reset the stack pointer

        ; --- Processor port: lock in our memory map ----------------------
        ; Write the data latch ($01) BEFORE the DDR ($00). If we made bits 0-2
        ; outputs first, they would drive the latch's reset value (0), pulling
        ; LORAM/HIRAM/CHAREN low and instantly unmapping the KERNAL ROM we are
        ; executing from -- the next instruction fetch would come from garbage.
        ; Writing the latch while the bits are still inputs is harmless (pull-
        ; ups keep the ROMs mapped); the DDR write then drives the right value.
        lda #CPU_PORT_STD
        sta CPU_PORT            ; latch = $37 (shell ROM + KERNAL ROM + I/O)
        lda #CPU_DDR_STD
        sta CPU_DDR             ; bits 0-5 outputs; now driving the latched $37

        ; --- Blank the display while we set up ---------------------------
        lda #CTRL1_BLANK
        sta VIC_CTRL1

        ; --- CIAs: stop timers, mask and clear all interrupts ------------
        ; SEI does not block NMIs, and CIA #2 drives the NMI line, so masking
        ; here is what actually guarantees a quiet machine.
        lda #$7f
        sta CIA1_ICR            ; disable all CIA #1 interrupt sources
        sta CIA2_ICR            ; disable all CIA #2 interrupt sources
        lda CIA1_ICR            ; read to clear any pending flags
        lda CIA2_ICR
        lda #$00
        sta CIA1_CRA            ; stop CIA #1 timers A/B
        sta CIA1_CRB
        sta CIA2_CRA            ; stop CIA #2 timers A/B
        sta CIA2_CRB

        ; --- VIC-II memory layout, bank, and colors ----------------------
        lda #MEMPTR_0400
        sta VIC_MEMPTR
        lda #CTRL2_40COL
        sta VIC_CTRL2
        lda CIA2_DDRA
        ora #$03
        sta CIA2_DDRA           ; bank-select bits are outputs
        lda CIA2_PRA
        ora #$03                ; %......11 -> VIC bank 0 ($0000-$3FFF)
        sta CIA2_PRA
        lda #COLOR_BLACK
        sta VIC_BORDER
        lda #COLOR_BLUE
        sta VIC_BGCOL

        ; --- Clear screen to spaces, color RAM to light blue -------------
        ldx #$00
        lda #SPACE
@clrscr:
        sta SCREEN_RAM + $000,x
        sta SCREEN_RAM + $100,x
        sta SCREEN_RAM + $200,x
        sta SCREEN_RAM + $2E8,x ; tail: covers through $07E7
        inx
        bne @clrscr

        ldx #$00
        lda #COLOR_LTBLUE
@clrcol:
        sta COLOR_RAM + $000,x
        sta COLOR_RAM + $100,x
        sta COLOR_RAM + $200,x
        sta COLOR_RAM + $2E8,x
        inx
        bne @clrcol

        ; --- Startup banner ----------------------------------------------
        PRINT banner1, SCREEN_RAM + 40 * 1 + 1
        PRINT banner2, SCREEN_RAM + 40 * 3 + 1

        ; --- Enable the display now that the screen is ready -------------
        lda #CTRL1_ON
        sta VIC_CTRL1

@halt:
        jmp @halt               ; static screen; input comes in Phase 3

; -------------------------------------------------------------------------
; puts_at: copy the zero-terminated ASCII string at (zp_src) to screen RAM
; at (zp_dst), converting ASCII to C64 screen codes as it goes. Handles the
; printable range used by the banner ($20-$5F). Clobbers A and Y.
; -------------------------------------------------------------------------
puts_at:
        ldy #$00
@loop:
        lda (zp_src),y
        beq @done               ; NUL terminator
        cmp #$40
        bcc @store              ; $20-$3F: screen code == ASCII
        and #$3f                ; $40-$5F ('@', 'A'-'Z', ...) -> $00-$1F
@store:
        sta (zp_dst),y
        iny
        bne @loop
@done:
        rts

banner1:
        .byte "C64 SHELL ROM V0.1", 0
banner2:
        .byte "READY.", 0

; --- 6502 hardware vectors ($FFFA-$FFFF) ---------------------------------
.segment "VECTORS"
        .addr nmi_stub          ; $FFFA NMI
        .addr reset             ; $FFFC RESET
        .addr irq_stub          ; $FFFE IRQ/BRK
