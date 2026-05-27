; c_io.s - C-callable shims over the KERNAL CHROUT/GETIN entry points.
;
; The C shell (src/shell.c) does its own I/O through these instead of cc65's
; conio, which assumes the stock C64 KERNAL we replaced. Both follow the cc65
; calling convention: a single char argument arrives in A, a char result is
; returned in A with the high byte (X) cleared.
;
; Placed in KCODE (KERNAL ROM) to keep all hand-written assembly together;
; the C side reaches them by symbol via cross-ROM JSR (both ROMs are mapped).

.export _chrout
.export _getin
.export _run_program

CHROUT = $FFD2
GETIN  = $FFE4

RUNVEC = $A7            ; free zero-page pair for the run_program indirect jump

.segment "KCODE"

; void chrout(unsigned char c);  -- character in A.
; CHROUT preserves A/X/Y and returns, so a tail JMP is all we need.
_chrout:
        jmp CHROUT

; unsigned char getin(void);  -- result in A, X = 0 (high byte of the int).
_getin:
        jsr GETIN
        ldx #$00
        rts

; void run_program(unsigned addr);  -- jump to a loaded program (A=lo, X=hi).
; Does not return; the program takes over the machine.
_run_program:
        sta RUNVEC
        stx RUNVEC+1
        jmp (RUNVEC)
