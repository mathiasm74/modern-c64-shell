; screen.s - Phase 3 screen output (CHROUT).
;
; Cursor-tracking character output: printable PETSCII goes to screen RAM (and
; color RAM) at the cursor, control codes handle CR / backspace / clear / home,
; and the screen scrolls when the cursor runs past the bottom row. Cursor state
; is kept in the standard KERNAL zero-page locations for compatibility.

.export chrout_impl
.export set_line_ptrs
.export screen_clear
.export pet2scr

; --- cursor state (KERNAL-compatible zero page) --------------------------
PNT    = $D1            ; $D1/$D2: pointer to start of the current screen line
PNTR   = $D3            ; cursor column (0-39)
TBLX   = $D6            ; cursor row (0-24)
USER   = $F3            ; $F3/$F4: pointer to start of the current color line
COLOR  = $0286          ; current text color

SAVE_X = $F5            ; CHROUT register save slots (not touched by the IRQ)
SAVE_Y = $F6
SAVE_A = $FA

SCREEN = $0400
CSCREEN = $D800
SPACE  = $20
COLOR_OFFSET = $D4      ; high-byte delta from screen RAM to color RAM ($D400)

.segment "KCODE"        ; hand-written core in the KERNAL ROM (see cfg/rom.cfg)

; -------------------------------------------------------------------------
; chrout_impl - print the PETSCII character in A. Preserves A, X, Y.
; -------------------------------------------------------------------------
chrout_impl:
        sta SAVE_A              ; save the character (restored on exit)
        stx SAVE_X
        sty SAVE_Y

        ; Lift the cursor: the current cell is shown in reverse video (the
        ; block), so clear that bit to get the real character back before we
        ; draw onto or past it.
        ldy PNTR
        lda (PNT),y
        and #$7F
        sta (PNT),y

        lda SAVE_A
        cmp #$0D
        beq @cr
        cmp #$14
        beq @bs
        cmp #$93
        beq @clr
        cmp #$13
        beq @home
        cmp #$1D
        beq @cright             ; cursor right
        cmp #$9D
        bne @notcleft
        jmp @cleft              ; cursor left (jmp: handler is out of branch range)
@notcleft:
        cmp #$20
        bcc @done               ; other $00-$1F control codes: ignore
        cmp #$80
        bcs @done               ; $80-$FF (function keys, graphics): ignore

        ; printable $20-$7F
        jsr pet2scr
        ldy PNTR
        sta (PNT),y             ; screen code
        lda COLOR
        sta (USER),y            ; color
        inc PNTR
        lda PNTR
        cmp #40
        bcc @done
        jsr do_newline          ; wrapped past column 39
@done:
        ; Draw the cursor: show the cell at the (possibly moved) cursor in
        ; reverse video -- a solid block. With white text on a blue screen
        ; that reads as a white block, and any character under it as blue.
        ldy PNTR
        lda (PNT),y
        ora #$80
        sta (PNT),y

        ldx SAVE_X
        ldy SAVE_Y
        lda SAVE_A              ; restore original character into A
        rts

@cr:
        jsr do_newline
        jmp @done
@bs:
        lda PNTR
        bne @bs_same            ; not at column 0: step left within the row
        lda TBLX                ; at column 0: wrap to column 39 of the prev row
        beq @done               ; top-left corner: nothing to delete
        dec TBLX
        lda #39
        sta PNTR
        jsr set_line_ptrs
        jmp @bs_blank
@bs_same:
        dec PNTR
@bs_blank:
        ldy PNTR
        lda #SPACE
        sta (PNT),y
        jmp @done
@clr:
        jsr screen_clear
        jmp @done
@home:
        lda #$00
        sta PNTR
        sta TBLX
        jsr set_line_ptrs
        jmp @done
@cright:                        ; move the cursor one column right
        lda PNTR
        cmp #39
        bcc @cr_same            ; not at the last column: just step right
        lda TBLX                ; at column 39: wrap to column 0 of the next row
        cmp #24
        bcs @done               ; bottom-right corner: stay put
        inc TBLX
        lda #$00
        sta PNTR
        jsr set_line_ptrs
        jmp @done
@cr_same:
        inc PNTR
        jmp @done
@cleft:                         ; move the cursor one column left
        lda PNTR
        bne @cl_same            ; not at column 0: just step left
        lda TBLX                ; at column 0: wrap to column 39 of the prev row
        beq @done               ; top-left corner: stay put
        dec TBLX
        lda #39
        sta PNTR
        jsr set_line_ptrs
        jmp @done
@cl_same:
        dec PNTR
        jmp @done

; -------------------------------------------------------------------------
; do_newline - column 0, advance one row, scrolling if past the bottom.
; -------------------------------------------------------------------------
do_newline:
        lda #$00
        sta PNTR
        inc TBLX
        lda TBLX
        cmp #25
        bcc @set
        jsr do_scroll
        lda #24
        sta TBLX
@set:
        jsr set_line_ptrs
        rts

; -------------------------------------------------------------------------
; set_line_ptrs - point PNT/USER at the start of row TBLX in screen/color RAM.
; -------------------------------------------------------------------------
set_line_ptrs:
        ldx TBLX
        lda line_lo,x
        sta PNT
        sta USER                ; color RAM shares the low byte
        lda line_hi,x
        sta PNT+1
        clc
        adc #COLOR_OFFSET
        sta USER+1
        rts

; -------------------------------------------------------------------------
; screen_clear - fill the screen with spaces, color RAM with COLOR, home.
; -------------------------------------------------------------------------
screen_clear:
        ldx #$00
        lda #SPACE
@s:
        sta SCREEN + $000,x
        sta SCREEN + $100,x
        sta SCREEN + $200,x
        sta SCREEN + $2E8,x
        inx
        bne @s
        ldx #$00
        lda COLOR
@c:
        sta CSCREEN + $000,x
        sta CSCREEN + $100,x
        sta CSCREEN + $200,x
        sta CSCREEN + $2E8,x
        inx
        bne @c
        lda #$00
        sta PNTR
        sta TBLX
        jsr set_line_ptrs
        rts

; -------------------------------------------------------------------------
; do_scroll - scroll the screen (and color RAM) up one line; blank the last.
; Moves 960 bytes up by 40, then clears the bottom row.
; -------------------------------------------------------------------------
do_scroll:
        ; Shift rows 1-24 up into rows 0-23 (960 bytes), one page at a time in
        ; strict address order. A single loop that interleaved the page copies
        ; would let a later page's early stores ($05xx/$06xx) overwrite an
        ; earlier page's source bytes before they were read -- which left two
        ; rows showing duplicated content after a scroll.
        ldx #$00
@s0:
        lda SCREEN + $028,x     ; page 0: $0428.. -> $0400..
        sta SCREEN + $000,x
        inx
        bne @s0
        ldx #$00
@s1:
        lda SCREEN + $128,x     ; page 1: $0528.. -> $0500..
        sta SCREEN + $100,x
        inx
        bne @s1
        ldx #$00
@s2:
        lda SCREEN + $228,x     ; page 2: $0628.. -> $0600..
        sta SCREEN + $200,x
        inx
        bne @s2
        ldx #$00
@s3:
        lda SCREEN + $328,x     ; page 3: remaining 192 bytes
        sta SCREEN + $300,x
        inx
        cpx #192
        bne @s3
        ldx #$00
        lda #SPACE
@s4:
        sta SCREEN + $3C0,x     ; blank the new bottom row ($07C0-$07E7)
        inx
        cpx #40
        bne @s4

        ldx #$00
@c0:
        lda CSCREEN + $028,x    ; color RAM: same page-by-page shift
        sta CSCREEN + $000,x
        inx
        bne @c0
        ldx #$00
@c1:
        lda CSCREEN + $128,x
        sta CSCREEN + $100,x
        inx
        bne @c1
        ldx #$00
@c2:
        lda CSCREEN + $228,x
        sta CSCREEN + $200,x
        inx
        bne @c2
        ldx #$00
@c3:
        lda CSCREEN + $328,x
        sta CSCREEN + $300,x
        inx
        cpx #192
        bne @c3
        ldx #$00
        lda COLOR
@c4:
        sta CSCREEN + $3C0,x
        inx
        cpx #40
        bne @c4
        rts

; -------------------------------------------------------------------------
; pet2scr - convert the ASCII/PETSCII code in A ($20-$7F) to a screen code.
;
; The encoding is ASCII-consistent against the lowercase/text charset (VIC
; charset @ $1800): lowercase letters draw as lowercase, uppercase as
; uppercase. Concretely:
;   $20-$3F  space/digits/punctuation -> unchanged
;   $40 '@'                           -> $00
;   $41-$5A 'A'-'Z'                   -> unchanged ($41-$5A = uppercase glyphs)
;   $5B-$5F  [ \ ] ^ _                -> -$40 ($1B-$1F)
;   $60-$7F  'a'-'z' and friends      -> -$60 ($61-$7A 'a'-'z' -> $01-$1A)
;   $DB-$DD  uppercase Swedish A E O  -> -$80 ($5B-$5D = AE/OE/Aring in the
;            (Ae Oe Aring)                Swedish charset's lower set)
; The lowercase swedish letters reuse $5B-$5D ('[' '\' ']') -> $1B-$1D, which
; the Swedish charset draws as ae/oe/aring; the uppercase variants live at the
; $5B-$5D screen codes, reached here from PETSCII $DB-$DD (= lowercase + $80).
; Preserves X and Y; clobbers A only.
; -------------------------------------------------------------------------
pet2scr:
        cmp #$DB
        bcs @hi                 ; $DB-$FF: uppercase Swedish range (see @hi)
        cmp #$40
        bcc @keep               ; $20-$3F: screen code == byte
        beq @at                 ; $40 '@' -> $00
        cmp #$5B
        bcc @keep               ; $41-$5A 'A'-'Z': uppercase glyphs, unchanged
        cmp #$60
        bcc @sub40              ; $5B-$5F -> -$40
        sec                     ; $60-$7F (lowercase a-z and friends) -> -$60
        sbc #$60
        rts
@at:
        lda #$00
        rts
@sub40:
        sec
        sbc #$40
@keep:
        rts
@hi:                            ; A >= $DB
        cmp #$DE
        bcs @keep               ; $DE-$FF: not ours -> leave unchanged
        sec
        sbc #$80                ; $DB/$DC/$DD -> $5B/$5C/$5D (upper Ae/Oe/Aring)
        rts

; --- per-row screen-line address tables (low/high bytes) -----------------
line_lo:
        .repeat 25, i
            .byte <(SCREEN + i * 40)
        .endrepeat
line_hi:
        .repeat 25, i
            .byte >(SCREEN + i * 40)
        .endrepeat
