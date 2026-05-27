; kernal_stubs.s - standard KERNAL entry points at their published addresses.
;
; The CPU and external software expect routines like CHROUT at fixed addresses
; ($FFD2 etc.). Each is a JMP into the real implementation, placed by the
; linker via a fixed-start segment. Only the Phase 3 entries (CHROUT, GETIN)
; exist so far; more arrive as later phases implement them.

.import chrout_impl
.export getin_impl

NDX    = $C6            ; keyboard buffer count
KEYBUF = $0277          ; keyboard buffer

.segment "KCODE"        ; hand-written core in the KERNAL ROM (see cfg/rom.cfg)

; -------------------------------------------------------------------------
; getin_impl - return the next character from the keyboard buffer in A, or
; A=0 (Z set) if the buffer is empty. Buffer access is made atomic against
; the IRQ-driven keyboard scan.
; -------------------------------------------------------------------------
getin_impl:
        php
        sei
        lda NDX
        bne @have
        plp
        lda #$00                ; empty: A=0, Z set
        rts
@have:
        ldy KEYBUF              ; character to return
        ldx #$01                ; shift the rest of the buffer down by one
@shift:
        cpx NDX
        bcs @done
        lda KEYBUF,x
        sta KEYBUF - 1,x
        inx
        bne @shift
@done:
        dec NDX
        plp
        tya                     ; A = character (sets Z/N)
        rts

; --- fixed-address jump table entries ------------------------------------
.segment "STUB_CHROUT"          ; linker places this at $FFD2
        jmp chrout_impl

.segment "STUB_GETIN"           ; linker places this at $FFE4
        jmp getin_impl
