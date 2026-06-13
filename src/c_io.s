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
.export _soft_reset

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

; void run_program(unsigned addr);  -- call a loaded program (A=lo, X=hi) like
; SYS: as a subroutine, so a program that ends in RTS returns to the shell.
; (6502 has no JSR-indirect: jsr to a trampoline that jmp()s into the program;
; the program's RTS pops back to the rts below, which returns to the caller.)
; A program that loops forever or resets the stack simply never returns.
_run_program:
        sta RUNVEC
        stx RUNVEC+1
        jsr @enter
        rts
@enter:
        jmp (RUNVEC)

; void soft_reset(void);  -- reboot through the reset vector. Does not return.
_soft_reset:
        jmp ($FFFC)

; ===========================================================================
; run_stub - autostart stub for `run` (src/commands/fs.c cmd_run).
;
; cmd_run copies these bytes to the tape buffer at $033C, plants a CBM80
; autostart structure at $8000 pointing here, writes the loaded program's
; load address to $0334/$0335 and its end (VARTAB) to $0336/$0337, then
; swaps the One ROM to the stock ROMs via rbcp_launch_stock. The stock
; KERNAL reset's cartridge-autostart path finds the planted CBM80 and JMPs
; here -- so this runs in the STOCK environment (stock ROMs mapped), with
; only the minimal init the cart path does (SEI/stack/CLD, no IOINIT/RAMTAS).
;
; It must therefore set the machine up itself. The cart path skips RAMTAS,
; which would clear pages 0-3 (including this stub and the $0334 params) --
; so we set the memory pointers by hand instead and never call it. The stub
; lives at $033C and the params at $0334-$0337, both above RESTOR's $0314-
; $0333 range, so IOINIT/RESTOR/CINT don't disturb them.
;
; Dispatch: a BASIC program (load address $0801) is run by initialising
; BASIC without the NEW that a cold start would do (which zeroes the
; program's first link bytes) -- $E453 (BASIC vectors) + $E3BF (BASIC RAM
; init: TXTTAB, CHRGET, $0800=0; preserves $0801+) -- then VARTAB is set to
; the program end, CLR links the rest, and $A7AE runs it. Anything else is
; treated as machine code: JMP through its load address.
;
; The stub runs at $CF00 and reads its params from $CFF8-$CFFB (above the
; RBCP/overlay RAM and the BASIC-ROM ceiling, so RAMTAS -- which the stub
; calls -- leaves them alone; RAMTAS clears pages 0-3, which is exactly why
; neither the stub nor its params can live in the tape buffer). RAMTAS gives
; BASIC the clean zero page it needs (our shell leaves cc65 leftovers there,
; which made the BASIC path fail unpredictably) and sets MEMSTR/MEMSIZ; its
; RAM test is non-destructive, so the loaded program survives. Position-
; independent (only PC-relative branches internally; all absolute refs are
; fixed stock addresses or the $CFF8 params). Addresses verified against
; kernal.901227-03 / basic.901226-01.
; ---------------------------------------------------------------------------
RUN_PARAMS = $CFF8              ; load lo/hi, end lo/hi (4 bytes)

.export _run_stub
.export _run_stub_end

_run_stub:
        sei
        ldx #$ff
        txs
        cld
        jsr $FF84               ; IOINIT  - CIA/VIC/SID
        jsr $FF87               ; RAMTAS  - clear ZP/pages 2-3, set MEMSTR/SIZ
        jsr $FF8A               ; RESTOR  - $0314-$0333 RAM vectors
        jsr $FF81               ; CINT    - screen editor (clears the screen)
        lda RUN_PARAMS+0        ; load address lo
        cmp #$01
        bne @ml
        lda RUN_PARAMS+1        ; load address hi
        cmp #$08
        bne @ml
        ; --- BASIC program at $0801 -------------------------------------
        ; RAMTAS already set MEMSTR=$0800 / MEMSIZ=$A000, which E3BF reads.
        jsr $E453               ; init BASIC indirect vectors ($0300-$030B)
        jsr $E3BF               ; init BASIC RAM (TXTTAB=$0801, no NEW)
        lda RUN_PARAMS+2        ; VARTAB = program end
        sta $2D
        lda RUN_PARAMS+3
        sta $2E
        jsr $A659               ; CLR - set TXTPTR, ARYTAB/STREND, FRETOP
        cli
        jmp $A7AE               ; RUN
@ml:    ; --- machine-code program: jump through its load address --------
        cli
        jmp (RUN_PARAMS)
_run_stub_end:
