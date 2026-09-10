; bank1.s - ROM-expansion PoC test bank (docs/ROM-EXPANSION.md, Option A).
;
; A self-contained 8KB ROM bank served at $A000-$BFFF in place of the base set's
; BASIC half (the KERNAL half is identical across sets, so the swap is live-safe
; -- the CPU runs from $E000 throughout). This bank proves the mechanism: it
; runs entirely from ROM at $A000, calls ONLY the static KERNAL half ($FFD2
; CHROUT), and touches no writable memory -- so a program loaded in user RAM is
; left untouched, which is the whole point of banks-over-RAM-overlays.
;
; ABI: a JMP table at $A000. The resident dispatcher, after SWITCH_SLOTing the
; served BASIC window to this bank, JSRs $A000 + 3*index. Entry 0 = bank_hello.
; Entries return with RTS; the dispatcher then SWITCH_SLOTs back to the base.

CHROUT = $FFD2                  ; static KERNAL stub -- present in every set
CR     = $0D

.segment "ENTRY"                ; linked first, so this lands at $A000
        jmp bank_hello          ; $A000  entry 0

.segment "CODE"

; entry 0: print a banner proving we ran from the swapped-in bank.
bank_hello:
        ldx #0
@loop:  lda msg,x
        beq @done
        jsr CHROUT
        inx
        bne @loop
@done:  lda #CR
        jsr CHROUT
        rts

.segment "RODATA"
msg:    .byte "hello from rom bank 1", 0
