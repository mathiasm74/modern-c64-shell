; ============================================================================
; memtest.s -- C64 hardware bus diagnostic ROM
;
; Self-contained 16KB replacement for the shell. On reset, configures the VIC
; for plain uppercase text, then reads known sentinel bytes hand-placed in the
; BASIC bank (see memtest_basic.s) and prints expected-vs-actual values to the
; screen. Helps distinguish:
;
;   A) Address-line faults -- adjacent reads alias or skip in a pattern that
;      maps to a stuck/floating address bit
;   B) Data-line faults    -- one or more data bits stuck high/low; the
;      walking-1 / walking-0 cells show which
;   C) BASIC /CS faults    -- BASIC reads return KERNAL contents, the fill
;      sentinel ($5A), or a constant float pattern, while the KERNAL-sanity
;      cell (read from KERNAL bank) reads correctly
;   D) Transient vs persistent -- the scan cell is read 1000 times; ERR
;      counts mismatches and LAST shows the last wrong value seen
;
; Output (40-col uppercase text). Mismatch rows go red, matches go green.
;
;   ROW 0   MEMTEST V1
;   ROW 2   BANK  A000 A800 B000 B800 BFFF
;   ROW 3   EXP    A0   A8   B0   B8   BF
;   ROW 4   READ   XX   XX   XX   XX   XX
;   ROW 6   D1   EXP 01 02 04 08 10 20 40 80
;   ROW 7   D1   RD  XX XX XX XX XX XX XX XX
;   ROW 9   D0   EXP FE FD FB F7 EF DF BF 7F
;   ROW 10  D0   RD  XX XX XX XX XX XX XX XX
;   ROW 12  KRNL EFFE EXP EF READ XX
;   ROW 14  SCAN A050 N=03E8 ERR=XXXX  LAST=XX
;
; Nothing here uses BASIC ROM reads except the deliberate test reads, so a
; completely dead BASIC bank does not prevent the test from running and
; displaying its results. The label strings, jump table, vectors, and even
; the test-vector tables all live in the KERNAL bank.
; ============================================================================

.export reset

VIC_CR1     = $D011
VIC_CR2     = $D016
VIC_MEM     = $D018
VIC_BORDER  = $D020
VIC_BG      = $D021
COLOR_RAM   = $D800
SCREEN_RAM  = $0400

; Zero-page scratch (we own the whole zero page; pick any safe locations).
PTR1     = $FB          ; string source ptr (used by puts)
SCRPTR   = $FD          ; screen-RAM write ptr (auto-advances)
COLPTR   = $F7          ; color-RAM write ptr (parallel to SCRPTR)
FAIL     = $F9          ; per-row fail flag (any non-zero = mismatch found)
ERR_LO   = $F4          ; transient: mismatch counter (lo)
ERR_HI   = $F3          ; transient: mismatch counter (hi)
LAST_BAD = $F2          ; transient: last wrong byte
TMP      = $F0          ; scratch (holds a read byte across puthex)

; Colors
COL_WHITE = $01
COL_RED   = $02
COL_GREEN = $05


; ============================================================================
.segment "KCODE"

; --- reset -----------------------------------------------------------------
; Entry point at $E000 (via $FFFC reset vector). Pure hardware init, no
; assumptions about anything other than KERNAL ROM and I/O being live.
reset:
        sei
        cld
        ldx #$FF
        txs

        ; Processor port: ROMs + I/O visible.
        ; Order matters: set the data register ($01) BEFORE the data-direction
        ; register ($00). If you set DDR first, the upper bits of $01 become
        ; outputs while still holding whatever the boot default was, which on
        ; the C64 can briefly drive LORAM/HIRAM low -- unmapping KERNAL ROM
        ; mid-instruction. The next opcode fetch then comes from RAM and the
        ; CPU wanders. Setting $01 first keeps the port at $37 throughout.
        lda #$37
        sta $01
        lda #$2F
        sta $00

        ; VIC: 25x40 text, charset @ $1000 (chargen uppercase ROM).
        lda #$15
        sta VIC_MEM
        lda #$1B
        sta VIC_CR1
        lda #$C8
        sta VIC_CR2
        lda #$06            ; blue border
        sta VIC_BORDER
        lda #$00            ; black background
        sta VIC_BG

        jsr clear_screen

        lda #0
        jsr seekrow
        ldx #<title
        ldy #>title
        jsr puts

        jsr test_banks          ; rows 2-4
        jsr test_data_walk1     ; rows 6-7
        jsr test_data_walk0     ; rows 9-10
        jsr test_kernal         ; row 12
        jsr test_transient      ; row 14

@halt:  jmp @halt


; --- clear_screen ----------------------------------------------------------
clear_screen:
        ldx #0
        lda #$20            ; space (screen code)
@cs:    sta SCREEN_RAM,x
        sta SCREEN_RAM+$100,x
        sta SCREEN_RAM+$200,x
        sta SCREEN_RAM+$2E8,x
        inx
        bne @cs
        ldx #0
        lda #COL_WHITE
@cc:    sta COLOR_RAM,x
        sta COLOR_RAM+$100,x
        sta COLOR_RAM+$200,x
        sta COLOR_RAM+$2E8,x
        inx
        bne @cc
        rts


; --- seekrow ---------------------------------------------------------------
; in:  A = row (0..24)
; out: SCRPTR -> $0400 + row*40; COLPTR -> $D800 + row*40
seekrow:
        tax
        lda row_lo,x
        sta SCRPTR
        sta COLPTR
        lda row_hi,x
        sta SCRPTR+1
        clc
        adc #$D4-$04
        sta COLPTR+1
        rts

row_lo:
        .byte $00, $28, $50, $78, $A0, $C8, $F0
        .byte $18, $40, $68, $90, $B8, $E0
        .byte $08, $30, $58, $80, $A8, $D0
        .byte $00, $28, $50, $78, $A0, $C8
row_hi:
        .byte $04, $04, $04, $04, $04, $04, $04
        .byte $05, $05, $05, $05, $05, $05
        .byte $06, $06, $06, $06, $06, $06
        .byte $07, $07, $07, $07, $07, $07


; --- puts ------------------------------------------------------------------
; in:  X/Y = lo/hi pointer to ASCII string (NUL-terminated, < 256 chars)
; effect: writes to (SCRPTR); advances both SCRPTR and COLPTR by string length.
; Converts ASCII $40-$5F to screen codes $00-$1F on the fly.
puts:
        stx PTR1
        sty PTR1+1
        ldy #0
@loop:  lda (PTR1),y
        beq @done
        cmp #$40
        bcc @write
        cmp #$60
        bcs @write
        and #$3F
@write: sta (SCRPTR),y
        iny
        bne @loop
@done:  tya
        clc
        adc SCRPTR
        sta SCRPTR
        bcc @noh
        inc SCRPTR+1
@noh:   tya
        clc
        adc COLPTR
        sta COLPTR
        bcc @ret
        inc COLPTR+1
@ret:   rts


; --- puthex ----------------------------------------------------------------
; in:  A = byte
; effect: writes 2 hex digits at (SCRPTR); advances SCRPTR + COLPTR by 2.
puthex:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr puthex_n
        pla
        and #$0F
puthex_n:
        ldy #0
        cmp #10
        bcc @digit
        sec
        sbc #9              ; A..F -> $01..$06 (screen)
        bcs @write
@digit: ora #$30            ; 0..9 -> $30..$39 (screen)
@write: sta (SCRPTR),y
        inc SCRPTR
        bne @ah
        inc SCRPTR+1
@ah:    inc COLPTR
        bne @done
        inc COLPTR+1
@done:  rts


; --- putc ------------------------------------------------------------------
; in:  A = screen code; writes at (SCRPTR), advances SCRPTR + COLPTR by 1.
putc:
        ldy #0
        sta (SCRPTR),y
        inc SCRPTR
        bne @ah
        inc SCRPTR+1
@ah:    inc COLPTR
        bne @done
        inc COLPTR+1
@done:  rts


; --- putspc ----------------------------------------------------------------
putspc:
        lda #$20
        jmp putc


; ============================================================================
; test_banks -- bank-identity / address-line sanity at 5 corners of BASIC
; ============================================================================
test_banks:
        lda #0
        sta FAIL

        ; Row 2: header
        lda #2
        jsr seekrow
        ldx #<lbl_bank_hdr
        ldy #>lbl_bank_hdr
        jsr puts

        ; Row 3: expected
        lda #3
        jsr seekrow
        ldx #<lbl_bank_exp
        ldy #>lbl_bank_exp
        jsr puts

        ; Row 4: read
        lda #4
        jsr seekrow
        ldx #<lbl_read
        ldy #>lbl_read
        jsr puts

        ; Five cells, each "  XX " (2 leading spaces, 2 hex, 1 trailing space),
        ; matching the column layout in lbl_bank_hdr / lbl_bank_exp.
        ; X = cell index 0..4. puthex/putc/putspc preserve X, so X stays
        ; intact across them; we use TMP to hold the read byte across puthex.
        ldx #0
@cell:  jsr putspc
        jsr putspc
        lda banks_lo,x
        sta PTR1
        lda banks_hi,x
        sta PTR1+1
        ldy #0
        lda (PTR1),y
        sta TMP
        jsr puthex
        lda TMP
        cmp banks_exp,x
        beq @ok
        lda #$FF
        sta FAIL
@ok:    jsr putspc
        inx
        cpx #5
        bne @cell

        ; Color the READ row.
        lda #4
        jsr seekrow
        ; Advance past "READ" (4 cols) on both pointers.
        lda SCRPTR
        clc
        adc #4
        sta SCRPTR
        lda COLPTR
        clc
        adc #4
        sta COLPTR
        lda FAIL
        beq :+
        lda #COL_RED
        bne @set
:       lda #COL_GREEN
@set:   ldx #26             ; covers all 5 cells + interior spaces
        ldy #0
@cl:    sta (COLPTR),y
        iny
        dex
        bne @cl
        rts

banks_lo:  .byte $00, $00, $00, $00, $FF
banks_hi:  .byte $A0, $A8, $B0, $B8, $BF
banks_exp: .byte $A0, $A8, $B0, $B8, $BF


; ============================================================================
; test_data_walk1 -- read $A100..$A107 (walking-1 pattern)
; ============================================================================
test_data_walk1:
        lda #0
        sta FAIL

        lda #6
        jsr seekrow
        ldx #<lbl_d1_exp
        ldy #>lbl_d1_exp
        jsr puts

        lda #7
        jsr seekrow
        ldx #<lbl_d1_rd
        ldy #>lbl_d1_rd
        jsr puts

        ldx #0
@cell:  lda $A100,x
        pha
        jsr puthex
        pla
        cmp walk1,x
        beq @ok
        lda #$FF
        sta FAIL
@ok:    jsr putspc
        inx
        cpx #8
        bne @cell

        lda #7
        jsr seekrow
        lda SCRPTR
        clc
        adc #8              ; past "D1   RD "
        sta SCRPTR
        lda COLPTR
        clc
        adc #8
        sta COLPTR
        lda FAIL
        beq :+
        lda #COL_RED
        bne @set
:       lda #COL_GREEN
@set:   ldx #24             ; 8 cells * 3 cols each (XX + space)
        ldy #0
@cl:    sta (COLPTR),y
        iny
        dex
        bne @cl
        rts


; ============================================================================
; test_data_walk0 -- read $A200..$A207 (walking-0 pattern)
; ============================================================================
test_data_walk0:
        lda #0
        sta FAIL

        lda #9
        jsr seekrow
        ldx #<lbl_d0_exp
        ldy #>lbl_d0_exp
        jsr puts

        lda #10
        jsr seekrow
        ldx #<lbl_d0_rd
        ldy #>lbl_d0_rd
        jsr puts

        ldx #0
@cell:  lda $A200,x
        pha
        jsr puthex
        pla
        cmp walk0,x
        beq @ok
        lda #$FF
        sta FAIL
@ok:    jsr putspc
        inx
        cpx #8
        bne @cell

        lda #10
        jsr seekrow
        lda SCRPTR
        clc
        adc #8
        sta SCRPTR
        lda COLPTR
        clc
        adc #8
        sta COLPTR
        lda FAIL
        beq :+
        lda #COL_RED
        bne @set
:       lda #COL_GREEN
@set:   ldx #24
        ldy #0
@cl:    sta (COLPTR),y
        iny
        dex
        bne @cl
        rts


; ============================================================================
; test_kernal -- sanity check: read sentinel $EFFE from KERNAL bank
; ============================================================================
test_kernal:
        lda #12
        jsr seekrow
        ldx #<lbl_krnl
        ldy #>lbl_krnl
        jsr puts                ; "KRNL EFFE EXP EF READ "

        lda $EFFE
        pha
        jsr puthex
        pla
        cmp #$EF
        beq @green
        lda #COL_RED
        bne @col
@green: lda #COL_GREEN
@col:   ; Recolor the 2 hex cells we just wrote.
        pha
        sec
        lda COLPTR
        sbc #2
        sta COLPTR
        bcs :+
        dec COLPTR+1
:       pla
        ldy #0
        sta (COLPTR),y
        iny
        sta (COLPTR),y
        rts


; ============================================================================
; test_transient -- read $A050 1000 times, count mismatches against $55
; ============================================================================
test_transient:
        lda #0
        sta ERR_LO
        sta ERR_HI
        sta LAST_BAD

        ; 1000 = 4 * 250
        ldx #4
@o:     ldy #250
@i:     lda $A050
        cmp #$55
        beq @m
        sta LAST_BAD
        inc ERR_LO
        bne @m
        inc ERR_HI
@m:     dey
        bne @i
        dex
        bne @o

        lda #14
        jsr seekrow
        ldx #<lbl_scan1
        ldy #>lbl_scan1
        jsr puts                ; "SCAN A050 N=03E8 ERR="

        lda ERR_HI
        jsr puthex
        lda ERR_LO
        jsr puthex

        ldx #<lbl_scan2
        ldy #>lbl_scan2
        jsr puts                ; "  LAST="

        lda LAST_BAD
        jsr puthex

        ; Color row red if any errors, green otherwise.
        lda #14
        jsr seekrow
        lda ERR_LO
        ora ERR_HI
        beq @green
        lda #COL_RED
        bne @set
@green: lda #COL_GREEN
@set:   ldx #33
        ldy #0
@cl:    sta (COLPTR),y
        iny
        dex
        bne @cl
        rts


; ============================================================================
; Reference data
; ============================================================================
walk1:  .byte $01, $02, $04, $08, $10, $20, $40, $80
walk0:  .byte $FE, $FD, $FB, $F7, $EF, $DF, $BF, $7F


; ============================================================================
; ASCII strings (puts converts $40-$5F to screen codes).
; Header / EXP / READ widths are tuned so values line up.
; ============================================================================

title:        .byte "MEMTEST V1", 0

lbl_bank_hdr: .byte "BANK  A000 A800 B000 B800 BFFF", 0
lbl_bank_exp: .byte "EXP    A0   A8   B0   B8   BF", 0
lbl_read:     .byte "READ", 0

lbl_d1_exp:   .byte "D1   EXP 01 02 04 08 10 20 40 80", 0
lbl_d1_rd:    .byte "D1   RD ", 0

lbl_d0_exp:   .byte "D0   EXP FE FD FB F7 EF DF BF 7F", 0
lbl_d0_rd:    .byte "D0   RD ", 0

lbl_krnl:     .byte "KRNL EFFE EXP EF READ ", 0

lbl_scan1:    .byte "SCAN A050 N=03E8 ERR=", 0
lbl_scan2:    .byte "  LAST=", 0


; ============================================================================
; KERNAL-bank sanity sentinel. Pinned to $EFFE via cfg/memtest.cfg so the
; KERNAL test routine can confirm KERNAL reads work.
; ============================================================================
.segment "MT_EFFE"
        .byte $EF


; ============================================================================
; 6502 hardware vectors. We don't enable IRQs, so the IRQ/BRK vector points
; back to reset as a defensive fallback.
; ============================================================================
.segment "VECTORS"
        .word reset             ; NMI
        .word reset             ; RESET
        .word reset             ; IRQ/BRK
