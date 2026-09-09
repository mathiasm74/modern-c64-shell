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

.import rbcp_nmi_escape         ; RAM NMI handler for the RUN/STOP+RESTORE escape
.import rbcp_escape_tramp       ; RAM swap-back: hooked on BASIC's IMAIN ($0302)

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
; Dispatch: a BASIC program (load address $0801) is set up exactly the way
; stock BASIC's own LOAD does ($A52A) -- $E453 (BASIC vectors) + $E3BF (BASIC
; RAM init: TXTTAB, CHRGET, $0800=0; preserves $0801+, no NEW), VARTAB seeded
; from the program end, $A659 CLR, then $A533 LINKPRG. LINKPRG is the piece a
; plain "init without NEW" leaves out: it walks the program from TXTTAB and
; rebuilds every line's forward-link pointer (and re-derives VARTAB). Without
; it a loaded program runs on whatever stale links the PRG carried, so RUN
; hits ?SYNTAX ERROR and LIST shows garbage -- which is why a `load` here then
; a bare swap couldn't RUN/LIST. After LINKPRG the mode byte at $CFFC decides:
; nonzero = JMP $A474 (drop to stock BASIC's READY. so the program can be LISTed
; / RUN by hand -- `basic`); 0 = auto-run (`run`): stuff "RUN"+CR into the
; keyboard buffer and JMP $A474 too, letting stock BASIC's READY/MAIN read and
; execute "RUN" through its own machinery -- more robust across the bank swap
; than hand-rolling JMP $A7AE, which came up blank. A one-shot IMAIN hook at
; $0302 (rbcp_imain_hook) skips the pre-RUN READY and swaps back to the shell
; when the program later returns to READY. Anything not loading at $0801 is
; machine code: JMP through its load address (mode ignored; the ML path keeps
; the direct rbcp_escape_tramp IMAIN hook for programs that exit via READY).
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
RUN_MODE   = $CFFC              ; 0 = RUN, nonzero = drop to BASIC READY.
RUN_DEV    = $CFFD              ; current device (FA) to restore -- see below
RUN_FIRST  = $CFFE              ; mode-0 run: 1 = skip the pre-RUN READY (IMAIN)
RUN_STUB_BASE = $CF00           ; where launch_stock_program copies the stub, so
                                ; an in-stub label's RUN address is BASE+offset
                                ; (the stub is assembled in ROM but runs here)

.export _run_stub
.export _run_stub_end
.export run_imain_hook          ; in-stub $0302 hook (test computes its RUN addr)

_run_stub:
        sei
        ldx #$ff
        txs
        cld
        jsr $FF84               ; IOINIT  - CIA/VIC/SID
        jsr $FF87               ; RAMTAS  - clear ZP/pages 2-3, set MEMSTR/SIZ
        jsr $FF8A               ; RESTOR  - $0314-$0333 RAM vectors
        jsr $FF81               ; CINT    - screen editor (clears the screen)
        ; Point the stock NMI vector at our RAM escape handler so RUN/STOP +
        ; RESTORE swaps the One ROM back to the shell (see rbcp_nmi_escape).
        ; RESTOR just set $0318 to the stock default ($FE47); override it now.
        ; The handler lives in the RBCP RAM block, copied before the swap.
        lda #<rbcp_nmi_escape
        sta $0318
        lda #>rbcp_nmi_escape
        sta $0319
        ; RAMTAS cleared $BA (current device / FA) to 0. A real LOAD"name",dev
        ; leaves it = dev, and programs read it (PEEK(186)) to choose the drive
        ; to OPEN -- with it 0 (= keyboard) an OPEN raises ?ILLEGAL DEVICE
        ; NUMBER. Restore the device the program was loaded from. (E453/E3BF
        ; below don't touch $BA, so once here is enough for both paths.)
        lda RUN_DEV
        sta $BA
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
        lda RUN_PARAMS+2        ; VARTAB = program end (LINKPRG refines it)
        sta $2D
        lda RUN_PARAMS+3
        sta $2E
        jsr $A659               ; CLR - set TXTPTR, ARYTAB/STREND, FRETOP
        jsr $A533               ; LINKPRG - rebuild line links + set VARTAB,
                                ;   exactly as stock BASIC's LOAD tail ($A52A)
        lda RUN_MODE
        bne @ready
        ; mode 0 (run): auto-type "RUN" + CR into the keyboard buffer and drop
        ; into the SAME READY entry mode 1 uses, so stock BASIC runs the program
        ; through its own proven machinery (READY -> MAIN's line input -> the RUN
        ; token handler's own CLR + interpreter loop). Hand-rolling it with
        ; JMP $A7AE across the bank swap gave a blank screen; "type RUN at READY"
        ; is what actually works (mode 1 lands there and a manual RUN succeeds),
        ; so we automate exactly that. An IMAIN hook ($0302) ignores the first
        ; READY -- letting MAIN read the buffered "RUN" -- and swaps back to the
        ; shell on the second (the program returned to READY). RUN_FIRST at
        ; $CFFE arms the skip. (mode 1 / READY installs no hook so `basic` stays.)
        lda #$52                ; "R" (uppercase PETSCII)
        sta $0277
        lda #$55                ; "U"
        sta $0278
        lda #$4E                ; "N"
        sta $0279
        lda #$0D                ; CR
        sta $027A
        lda #4
        sta $C6                 ; NDX = 4 chars pending in the keyboard buffer
        lda #1
        sta RUN_FIRST           ; skip the pre-RUN READY (see run_imain_hook)
        ; $0302 -> run_imain_hook at its RUN address ($CF00 + its offset in the
        ; stub); the stub is assembled in ROM but always copied to $CF00.
        lda #<(RUN_STUB_BASE + (run_imain_hook - _run_stub))
        sta $0302
        lda #>(RUN_STUB_BASE + (run_imain_hook - _run_stub))
        sta $0303
        cli
        jmp $A474               ; READY. -> MAIN reads "RUN" -> runs the program
@ready: cli
        jmp $A474               ; READY. - stock BASIC immediate mode (LIST/RUN)
@ml:    ; --- machine-code program: jump through its load address --------
        ; Same IMAIN hook for mode 0: an ML program that quits by returning to
        ; BASIC READY (the usual fb/pterm exit) then bounces back to the shell.
        lda RUN_MODE
        bne @ml_go
        lda #<rbcp_escape_tramp
        sta $0302
        lda #>rbcp_escape_tramp
        sta $0303
@ml_go: cli
        jmp (RUN_PARAMS)

; --- mode-0 IMAIN ($0302) hook -- runs at $CF00 + (here - _run_stub) ---------
; Reached only via BASIC's JMP ($0302) at each READY, never fallen into. First
; READY (RUN_FIRST=1, set above) is the one $A474 does BEFORE MAIN reads the
; buffered "RUN": clear the flag and chain to the real MAIN ($A483) so it runs
; the program. The next READY -- the program has ended and returned -- swaps
; back to the shell. (rbcp_escape_tramp lives in the RBCP RAM block at $C800,
; only reached on this second pass, so it is fine that a bare stock/VICE test
; without that block never executes it: a looping test program never returns.)
run_imain_hook:
        lda RUN_FIRST
        beq @escape             ; second READY: program done -> back to the shell
        lda #0
        sta RUN_FIRST           ; consume the pre-RUN READY
        jmp $A483               ; stock BASIC MAIN: read + execute the buffered "RUN"
@escape:
        jmp rbcp_escape_tramp
_run_stub_end:
