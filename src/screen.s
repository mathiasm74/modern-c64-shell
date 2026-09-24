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
.export scr_display

; --- cursor state (KERNAL-compatible zero page) --------------------------
PNT    = $D1            ; $D1/$D2: pointer to start of the current screen line
PNTR   = $D3            ; cursor column (0-39)
TBLX   = $D6            ; cursor row (0-24)
USER   = $F3            ; $F3/$F4: pointer to start of the current color line
COLOR  = $0286          ; current text color
RVS    = $C7            ; reverse mode, the KERNAL's own cell: $80 = draw reversed
                        ; (a mask, so drawing costs one ORA), 0 = off. $12 sets
                        ; it, $92 and RETURN clear it, as on the stock KERNAL

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
        cmp #$20
        bcc @control            ; $00-$1F: control codes
        cmp #$80
        bcc @draw               ; $20-$7F: printable
        cmp #$A0
        bcs @draw               ; $A0-$FF: the PETSCII graphics (which include
                                ; the uppercase Swedish Ae/Oe/Aring at $DB-$DD)
@control:                       ; $80-$9F and $00-$1F
        jsr chrout_control
        jmp @done

@draw:
        jsr pet2scr
        ora RVS                 ; $80 while RVS is on: the reversed glyph
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

; -------------------------------------------------------------------------
; chrout_control - act on the control code in A (chrout_impl has lifted the
; cursor and redraws it afterwards). A routine of its own so its handlers sit
; within branch range of this compare chain; they used to share chrout_impl's,
; with the drawing code in between, and had run out of room.
; -------------------------------------------------------------------------
chrout_control:
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
        beq @cleft              ; cursor left
        cmp #$92
        beq @rvsoff
        cmp #$12
        bne @rts                ; every other code (colours etc.) is ignored
        lda #$80                ; RVS ON
        bne @rvsset             ; always
@cr:
        jsr do_newline          ; RETURN also ends reverse mode, as on the stock
@rvsoff:                        ; KERNAL (a column wrap does not)
        lda #0
@rvsset:
        sta RVS
@rts:   rts
@clr:
        jmp screen_clear
@bs:
        lda PNTR
        bne @bs_same            ; not at column 0: step left within the row
        lda TBLX                ; at column 0: wrap to column 39 of the prev row
        beq @rts                ; top-left corner: nothing to delete
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
        rts
@home:
        lda #$00
        sta PNTR
        sta TBLX
        jmp set_line_ptrs
@cright:                        ; move the cursor one column right
        lda PNTR
        cmp #39
        bcc @cr_same            ; not at the last column: just step right
        lda TBLX                ; at column 39: wrap to column 0 of the next row
        cmp #24
        bcs @rts                ; bottom-right corner: stay put
        inc TBLX
        lda #$00
        sta PNTR
        jmp set_line_ptrs
@cr_same:
        inc PNTR
        rts
@cleft:                         ; move the cursor one column left
        lda PNTR
        bne @cl_same            ; not at column 0: just step left
        lda TBLX                ; at column 0: wrap to column 39 of the prev row
        beq @rts                ; top-left corner: stay put
        dec TBLX
        lda #39
        sta PNTR
        jmp set_line_ptrs
@cl_same:
        dec PNTR
        rts

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
        cmp #$A0
        bcs @graphics           ; $A0-$FF: PETSCII graphics (see @graphics)
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
; PETSCII graphics, the standard mapping:
;   $A0-$BF -> screen $60-$7F   (-$40)
;   $C0-$FF -> screen $40-$7F   (-$80)
; The uppercase Swedish Ae/Oe/Aring ($DB/$DC/$DD -> $5B/$5C/$5D) used to be a
; special case here; it is the SAME arithmetic as the $C0-$FF rule, so it is
; simply covered now -- and the rest of the graphics set came with it.
@graphics:
        cmp #$C0
        bcs @sub80
        sec
        sbc #$40
        rts
@sub80: sec
        sbc #$80
        rts

; scr_display - screen code for ANY byte, the way a text editor must draw it.
;
; pet2scr covers the printable ranges, which is all CHROUT needs: it ACTS on a
; control code rather than drawing one. An editor has the opposite job -- every
; byte in the document has to appear as something, including the control codes
; a BASIC string legitimately carries (colours, cursor moves). So this adds the
; quote-mode rule the C64 itself uses, in reverse video:
;
;   $00-$1F  ->  screen code c, reversed
;   $80-$9F  ->  screen code (c & $1F) + $40, reversed
;
; Those two lines were MEASURED against the stock KERNAL (see
; test_runstub::test_control_code_glyphs_match_the_kernal) -- the obvious
; c & $7F collapses red and purple onto one glyph.
;
; It lives here, in the KERNAL half, because every bank can reach it through the
; SVC table: the text editor had its own 96-byte runtime table plus three
; helpers for exactly this, and the hex editor would have been a third copy.
scr_display:
        cmp #$20
        bcc @revlow             ; $00-$1F: reverse of the code itself
        cmp #$80
        bcc pet2scr             ; $20-$7F: ordinary printable
        cmp #$A0
        bcs pet2scr             ; $A0-$FF: graphics, pet2scr has them
        and #$1F                ; $80-$9F: reverse of (c & $1F) + $40
        clc
        adc #$40
@revlow:
        ora #$80
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
