; kbdiag.s - live keyboard-matrix viewer (the `debug` command).
;
; Rides in the UTIL BANK: self-contained assembly needing no cc65 runtime, so
; like `about` and the completion matcher it costs the 16KB ROM nothing but a
; dispatch row, and costs the program load area nothing at all.
;
; WHY THIS EXISTS. A real machine lost all eight keys on ONE select line
; (PA4: 9 I J 0 M K O N) while every other line worked. Nothing in software can
; tell you that from the outside -- the keys simply produce no characters, and
; the decode tables look fine because they ARE fine. This shows the raw matrix
; as the CIA reports it, refreshed as fast as the CPU can scan, so a marginal
; connection can be FOUND: hold a key on the dead line and wiggle the keyboard
; connector, and either its cell flickers (the contact is intermittent -- clean
; or reflow it) or it never moves at all (the line is open, so follow it from
; CIA1 U1 pin 2+n back to the keyboard).
;
; It reads the matrix DIRECTLY rather than showing the decoded key, which is the
; whole point: it sits below the decode tables, the debounce and the repeat
; logic, so what it draws is the hardware and nothing else.

CHROUT    = $FFD2
CIA1_PRA  = $DC00               ; column select (output, 0 = driven)
CIA1_PRB  = $DC01               ; row read (input, 0 = key closed)
CIA1_DDRA = $DC02
CIA1_DDRB = $DC03
SCREEN    = $0400

; Zero-page scratch. $FB-$FE are reset.s's string-drawing pointers -- used only
; during boot -- and the completion matcher's walk pointers, which cannot be
; running while this is (both live in this same bank).
scrptr    = $FB                 ; $FB/$FC: screen cell for the row being drawn
colmask   = $FD                 ; the walking zero
rowbits   = $FE                 ; the byte just read back

GRIDROW   = 4                   ; first screen row of the grid
GRIDCOL   = 6                   ; screen column of cell 0
CELLGAP   = 3                   ; columns between cells
HEXOFF    = 26                  ; hex column, relative to GRIDCOL

        .export kbdiag_main
        .segment "CODE"

kbdiag_main:
        ldx #0
@hdr:   lda header,x
        beq @go
        jsr CHROUT
        inx
        bne @hdr

@go:    sei                     ; the IRQ scan drives PRA too -- take the port,
                                ; or it would overwrite our select mid-read
        lda #$FF
        sta CIA1_DDRA           ; columns = outputs
        lda #$00
        sta CIA1_DDRB           ; rows = inputs

@frame:
        lda #$FE                ; walking zero, starting at PA0
        sta colmask
        lda #<(SCREEN + GRIDROW * 40 + GRIDCOL)
        sta scrptr
        lda #>(SCREEN + GRIDROW * 40 + GRIDCOL)
        sta scrptr+1
        ldx #8                  ; eight select lines to sample

@col:   lda colmask
        sta CIA1_PRA            ; drive this one low
        ldy #$00                ; (and settle before reading -- see irq.s)
.repeat 5
        nop
.endrepeat
        lda CIA1_PRB
        sta rowbits

        ; The raw byte in hex, so a whole line reading $FF is unmistakable.
        lsr a
        lsr a
        lsr a
        lsr a
        jsr hexdig
        ldy #HEXOFF
        sta (scrptr),y
        lda rowbits
        and #$0F
        jsr hexdig
        ldy #HEXOFF+1
        sta (scrptr),y

        ; One cell per row: '*' closed, '.' open.
        ldy #$00
@row:   lsr rowbits             ; low bit out into carry
        lda #$2E                ; '.' -- screen codes $20-$3F are ASCII here
        bcs @put
        lda #$2A                ; '*'
@put:   sta (scrptr),y
        iny
        iny
        iny
        cpy #8*CELLGAP
        bcc @row

        clc                     ; next screen row
        lda scrptr
        adc #40
        sta scrptr
        bcc :+
        inc scrptr+1
:       sec                     ; rotate the zero to the next select line
        rol colmask
        dex
        bne @col

        ; RUN/STOP quits -- matrix 63, PA7 row 7, which is on a line we know
        ; works (it is how the user got here). Read it the same careful way.
        lda #$7F
        sta CIA1_PRA
        ldy #$00
.repeat 5
        nop
.endrepeat
        lda CIA1_PRB
        and #$80
        bne @frame              ; STOP not held -> draw another frame

        lda #$FF
        sta CIA1_PRA            ; leave no line driven
        cli
        lda #$93                ; clear, so the prompt comes back to a sane screen
        jmp CHROUT

; A = $00-$0F -> screen code. Digits are $30-$39; the shell runs the LOWERCASE
; charset, where 'a'-'f' are screen codes $01-$06.
hexdig:
        cmp #10
        bcc @dig
        sbc #9                  ; carry is set here: A-10+1 = $01..$06
        rts
@dig:   ora #$30
        rts

        .segment "RODATA"

header:
        .byte $93               ; clear screen
        .byte "keyboard matrix - the raw cia bits", $0D, $0D
        .byte "      r0 r1 r2 r3 r4 r5 r6 r7   hex", $0D, $0D
        .byte "pa0", $0D, "pa1", $0D, "pa2", $0D, "pa3", $0D
        .byte "pa4", $0D, "pa5", $0D, "pa6", $0D, "pa7", $0D
        .byte $0D
        .byte "* closed  . open", $0D, $0D
        .byte "a whole pa line stuck at ff is a dead", $0D
        .byte "select line, not a dead key. hold one", $0D
        .byte "of its keys and wiggle the keyboard", $0D
        .byte "connector: flicker means a dirty", $0D
        .byte "contact, nothing means an open line.", $0D
        .byte $0D
        .byte "run/stop quits.", 0
