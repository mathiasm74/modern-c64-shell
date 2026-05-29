; ============================================================================
; memtest.s -- C64 hardware bus diagnostic ROM (no-stack edition)
;
; Self-contained 16KB replacement for the shell. Designed for hardware where
; the bus is known-unreliable (the whole point), so this variant intentionally
; avoids anything that would amplify a flaky bus:
;
;   - NO JSR / RTS         (return-address pops would corrupt)
;   - NO PHA / PLA         (same problem, smaller scope)
;   - NO subroutines       (every "call" is inlined via macros)
;   - Minimal RAM writes   (the few we make are screen RAM, written once)
;   - All conversions use registers, not zero page
;
; Color RAM IS initialized at boot to white-on-black, so all written text is
; visible (without this, power-on random color RAM made cells whose random
; color happened to equal the background look invisible, and reverse-video
; bytes from corrupted writes paint solid color blocks).
;
; The border color is set at each test stage as a "got this far" indicator.
; Even if the rendering hangs or the CPU escapes mid-test, the border tells
; you the latest stage that completed:
;
;   blue        $06   -- boot reached, labels not painted yet
;   light blue  $0E   -- labels painted (KERNAL ROM walker succeeded)
;   cyan        $03   -- BANK reads done
;   green       $05   -- D1 (walking-1) reads done
;   yellow      $07   -- D0 (walking-0) reads done
;   orange      $08   -- KRNL sanity read done
;   white       $01   -- SCAN done; all tests complete; entering halt
;
; Layout (40-col uppercase text, $D018=$15). The 2-char "BANK" labels on
; row 2 carry double duty: each is both the column header (A0 = $A000,
; A8 = $A800, etc.) and the expected value. Row 3 shows what was actually
; read. Compare row 2 to row 3 cell-by-cell.
;
;   ROW 0    MEMTEST V2
;   ROW 2    BANK A0 A8 B0 B8 BF
;   ROW 3         XX XX XX XX XX
;   ROW 5    D1 EXP 01 02 04 08 10 20 40 80
;   ROW 6    D1  RD XX XX XX XX XX XX XX XX
;   ROW 8    D0 EXP FE FD FB F7 EF DF BF 7F
;   ROW 9    D0  RD XX XX XX XX XX XX XX XX
;   ROW 11   KRNL EFFE EXP EF RD XX
;   ROW 13   SCAN A050 N=03E8 ERR=XXXX LAST=XX
;
; The bank, D1, D0, KRNL, and SCAN sections execute sequentially. If any
; section makes it onto the screen, every section before it ran to
; completion -- there are no leftover stack frames to corrupt, no pending
; subroutines to return to.
;
; SCAN is the only loop; it counts mismatches against $55 across 1000 reads
; of $A050. The counter sits in two zero-page bytes that are written and
; read entirely within this routine; if a write loses a bit, the count is
; off but the test still terminates and prints something.
; ============================================================================

.export reset

SCREEN_RAM = $0400
VIC_CR1    = $D011
VIC_CR2    = $D016
VIC_MEM    = $D018
VIC_BORDER = $D020
VIC_BG     = $D021

; Zero-page scratch. SRC/DST are only used by the label-painting walker;
; SC_* are only used by the SCAN section. The two phases never overlap, so
; we reuse the same locations.
SRC     = $F0
DST     = $F2
SC_LO   = $F0
SC_HI   = $F1
SC_LAST = $F2

; ============================================================================
; Macro: inline byte-to-hex on screen.
;
;   HEX_BYTE src, scr
;     reads byte at `src` (any addressing mode literal),
;     writes 2 hex screen codes at `scr` and `scr+1`.
;   Uses A and X. Leaves X = the read byte for easy follow-up comparisons.
;   No stack. No subroutines.
; ============================================================================
.macro HEX_BYTE src, scr
        lda src
        tax                 ; X keeps the byte for the low nibble
        lsr
        lsr
        lsr
        lsr                 ; A = high nibble (0..15)
        cmp #10
        bcc :+
        sec
        sbc #9              ; A..F -> screen $01..$06
        bcs :++
:       ora #$30            ; 0..9 -> screen $30..$39
:       sta scr
        txa
        and #$0F            ; A = low nibble
        cmp #10
        bcc :+
        sec
        sbc #9
        bcs :++
:       ora #$30
:       sta scr+1
.endmacro

; ============================================================================
.segment "KCODE"

reset:
        sei
        cld
        ldx #$FF
        txs                 ; (stack init is harmless even if we don't use it)

        ; Processor port: ROMs + I/O visible. $01 BEFORE $00 (see comment
        ; further down; reversing this ordering crashes on real C64).
        lda #$37
        sta $01
        lda #$2F
        sta $00

        ; VIC: 25x40 text, charset $1000 (chargen uppercase).
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

        ; --- Clear screen and color RAM (visible 1000 cells of each). ---
        ; Color RAM at $D800: white ($01) so every char is visible against
        ; the black background. (Without this init, power-on random color
        ; RAM made parts of the test output invisible.)
        ldx #0
@cls0:  lda #$20                    ; space (screen code)
        sta SCREEN_RAM,x
        sta SCREEN_RAM+$100,x
        sta SCREEN_RAM+$200,x
        sta SCREEN_RAM+$2E8,x
        lda #$01                    ; white
        sta $D800,x
        sta $D800+$100,x
        sta $D800+$200,x
        sta $D800+$2E8,x
        inx
        bne @cls0

        ; --- Paint static labels into screen RAM via a self-incrementing
        ; pointer (no LDX,X overflow at 256 bytes). label_tbl is a packed
        ; list of (dst_lo, dst_hi, ...bytes..., $00) entries terminated by
        ; a (dst_hi == $FF) entry. Only Y=0 is used for indirect addressing.
        lda #<label_tbl
        sta SRC
        lda #>label_tbl
        sta SRC+1
        ldy #0

@lbl_outer:
        ; Read dst_lo.
        lda (SRC),y
        sta DST
        ; Advance SRC.
        inc SRC
        bne :+
        inc SRC+1
:       ; Read dst_hi.
        lda (SRC),y
        sta DST+1
        cmp #$FF                ; $FF marks end-of-table
        beq @lbl_done
        ; Advance SRC.
        inc SRC
        bne :+
        inc SRC+1
:       ; Copy bytes until $00 from (SRC) to (DST).
@lbl_inner:
        lda (SRC),y
        beq @lbl_skip_nul
        sta (DST),y
        ; Advance DST.
        inc DST
        bne :+
        inc DST+1
:       ; Advance SRC.
        inc SRC
        bne :+
        inc SRC+1
:       jmp @lbl_inner
@lbl_skip_nul:
        ; Skip past the $00 terminator and go to the next entry.
        inc SRC
        bne :+
        inc SRC+1
:       jmp @lbl_outer
@lbl_done:

        ; --- Stage marker: labels painted (KERNAL ROM walker survived).
        lda #$0E                    ; light blue
        sta VIC_BORDER

        ; ====================================================================
        ; Static data done. Now the live ROM-read cells.
        ; ====================================================================

        ; --- Row 3: BANK reads. Each cell is 3 cols wide ("XX "); first at
        ; col 5 (under "A0" in row 2's "BANK A0 A8 B0 B8 BF" header).
        HEX_BYTE $A000, SCREEN_RAM + 3*40 + 5
        HEX_BYTE $A800, SCREEN_RAM + 3*40 + 8
        HEX_BYTE $B000, SCREEN_RAM + 3*40 + 11
        HEX_BYTE $B800, SCREEN_RAM + 3*40 + 14
        HEX_BYTE $BFFF, SCREEN_RAM + 3*40 + 17

        ; --- Stage marker: BANK done.
        lda #$03                    ; cyan
        sta VIC_BORDER

        ; --- Row 6: D1 reads ($A100..$A107). ---
        ; "D1  RD 01 02 04 08 10 20 40 80"
        HEX_BYTE $A100, SCREEN_RAM + 6*40 + 7
        HEX_BYTE $A101, SCREEN_RAM + 6*40 + 10
        HEX_BYTE $A102, SCREEN_RAM + 6*40 + 13
        HEX_BYTE $A103, SCREEN_RAM + 6*40 + 16
        HEX_BYTE $A104, SCREEN_RAM + 6*40 + 19
        HEX_BYTE $A105, SCREEN_RAM + 6*40 + 22
        HEX_BYTE $A106, SCREEN_RAM + 6*40 + 25
        HEX_BYTE $A107, SCREEN_RAM + 6*40 + 28

        ; --- Stage marker: D1 (walking-1) done.
        lda #$05                    ; green
        sta VIC_BORDER

        ; --- Row 9: D0 reads ($A200..$A207). ---
        HEX_BYTE $A200, SCREEN_RAM + 9*40 + 7
        HEX_BYTE $A201, SCREEN_RAM + 9*40 + 10
        HEX_BYTE $A202, SCREEN_RAM + 9*40 + 13
        HEX_BYTE $A203, SCREEN_RAM + 9*40 + 16
        HEX_BYTE $A204, SCREEN_RAM + 9*40 + 19
        HEX_BYTE $A205, SCREEN_RAM + 9*40 + 22
        HEX_BYTE $A206, SCREEN_RAM + 9*40 + 25
        HEX_BYTE $A207, SCREEN_RAM + 9*40 + 28

        ; --- Stage marker: D0 (walking-0) done.
        lda #$07                    ; yellow
        sta VIC_BORDER

        ; --- Row 11: KRNL sanity ($EFFE = $EF). Goes after "RD " at col 20.
        HEX_BYTE $EFFE, SCREEN_RAM + 11*40 + 20

        ; --- Stage marker: KRNL sanity done.
        lda #$08                    ; orange
        sta VIC_BORDER

        ; --- Row 13: transient SCAN (1000 reads of $A050; expect $55). ---
        ; Counters live entirely in our zero page. We avoid macros here to
        ; keep the tight loop as small as possible.
        lda #0
        sta SC_LO
        sta SC_HI
        sta SC_LAST

        ; 1000 = 4 * 250
        ldx #4
@so:    ldy #250
@si:    lda $A050
        cmp #$55
        beq @sm
        sta SC_LAST
        inc SC_LO
        bne @sm
        inc SC_HI
@sm:    dey
        bne @si
        dex
        bne @so

        ; Render ERR=XXXX
        HEX_BYTE SC_HI,  SCREEN_RAM + 13*40 + 21
        HEX_BYTE SC_LO,  SCREEN_RAM + 13*40 + 23
        ; Render LAST=XX
        HEX_BYTE SC_LAST, SCREEN_RAM + 13*40 + 32

        ; --- Stage marker: all tests complete.
        lda #$01                    ; white
        sta VIC_BORDER

        ; --- Halt. The CPU sits in this 3-byte loop forever. If an
        ; instruction-fetch glitch ever returns something other than the
        ; expected $4C (JMP) for the opcode byte, the CPU escapes and starts
        ; executing wild code (we've seen it stomp screen + color RAM + VIC
        ; registers on this hardware). We can't prevent the glitch, but we
        ; can stack multiple redundant JMPs so that even if execution does
        ; slip forward by one or two bytes, the next instruction lands on
        ; another JMP back to the halt label.
@halt:  jmp @halt
        jmp @halt
        jmp @halt
        jmp @halt
        jmp @halt


; ============================================================================
; label_tbl -- packed list of (lo, hi, ...bytes..., $00) triples; the table
; itself terminates with $FF. Each "block" places a run of screen codes
; starting at the given screen-RAM address. The bytes are already in screen-
; code form (we precompute the .byte values rather than convert at runtime).
;
; Screen-code cheat sheet (chargen uppercase mode):
;   space = $20
;   '0'..'9' = $30..$39
;   'A'..'Z' = $01..$1A
;   '='      = $3D
; (the labels below are written in this encoding directly)
; ============================================================================

label_tbl:
        ; ROW 0: "MEMTEST V2" at col 0
        .byte <($0400 + 0*40), >($0400 + 0*40)
        .byte $0D, $05, $0D, $14, $05, $13, $14, $20, $16, $32
        .byte 0

        ; ROW 2: "BANK A0 A8 B0 B8 BF" (19 chars)
        ; Each 2-char label is both the column header and the expected value:
        ; A0 = $A000 expected $A0, A8 = $A800 expected $A8, etc.
        .byte <($0400 + 2*40), >($0400 + 2*40)
        .byte $02, $01, $0E, $0B            ; "BANK"
        .byte $20
        .byte $01, $30                      ; "A0"
        .byte $20
        .byte $01, $38                      ; "A8"
        .byte $20
        .byte $02, $30                      ; "B0"
        .byte $20
        .byte $02, $38                      ; "B8"
        .byte $20
        .byte $02, $06                      ; "BF"
        .byte 0

        ; ROW 3: blank (HEX_BYTE writes the actuals at cols 5, 8, 11, 14, 17).

        ; ROW 5: "D1 EXP 01 02 04 08 10 20 40 80"
        .byte <($0400 + 5*40), >($0400 + 5*40)
        .byte $04, $31, $20, $05, $18, $10 ; "D1 EXP"
        .byte $20, $30, $31, $20, $30, $32, $20, $30, $34, $20, $30, $38
        .byte $20, $31, $30, $20, $32, $30, $20, $34, $30, $20, $38, $30
        .byte 0

        ; ROW 6: "D1  RD" prefix
        .byte <($0400 + 6*40), >($0400 + 6*40)
        .byte $04, $31, $20, $20, $12, $04 ; "D1  RD"
        .byte 0

        ; ROW 8: "D0 EXP FE FD FB F7 EF DF BF 7F"
        .byte <($0400 + 8*40), >($0400 + 8*40)
        .byte $04, $30, $20, $05, $18, $10 ; "D0 EXP"
        .byte $20, $06, $05, $20, $06, $04, $20, $06, $02, $20, $06, $37
        .byte $20, $05, $06, $20, $04, $06, $20, $02, $06, $20, $37, $06
        .byte 0

        ; ROW 9: "D0  RD" prefix
        .byte <($0400 + 9*40), >($0400 + 9*40)
        .byte $04, $30, $20, $20, $12, $04 ; "D0  RD"
        .byte 0

        ; ROW 11: "KRNL EFFE EXP EF RD " (20 chars; HEX_BYTE writes at col 20)
        .byte <($0400 + 11*40), >($0400 + 11*40)
        .byte $0B, $12, $0E, $0C, $20                   ; "KRNL "
        .byte $05, $06, $06, $05, $20                   ; "EFFE "
        .byte $05, $18, $10, $20                        ; "EXP "
        .byte $05, $06, $20                             ; "EF "
        .byte $12, $04, $20                             ; "RD "
        .byte 0

        ; ROW 13: "SCAN A050 N=03E8 ERR=     LAST="
        .byte <($0400 + 13*40), >($0400 + 13*40)
        .byte $13, $03, $01, $0E                ; "SCAN"
        .byte $20
        .byte $01, $30, $35, $30                ; "A050"
        .byte $20
        .byte $0E, $3D, $30, $33, $05, $38      ; "N=03E8"
        .byte $20
        .byte $05, $12, $12, $3D                ; "ERR="
        .byte $20, $20, $20, $20, $20           ; placeholder for "XXXX "
        .byte $20
        .byte $0C, $01, $13, $14, $3D           ; "LAST="
        .byte 0

        .byte $FF           ; end of table


; ============================================================================
; 6502 hardware vectors. No IRQs enabled; IRQ/BRK vector points back to
; `reset` as a defensive fallback.
; ============================================================================
.segment "VECTORS"
        .word reset             ; NMI
        .word reset             ; RESET
        .word reset             ; IRQ/BRK


; ============================================================================
; KERNAL-bank sanity sentinel. Pinned to $EFFE via cfg/memtest.cfg.
; ============================================================================
.segment "MT_EFFE"
        .byte $EF
