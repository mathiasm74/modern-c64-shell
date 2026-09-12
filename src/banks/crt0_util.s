; crt0_util.s - entry layer for the UTIL BANK (docs/ROM-EXPANSION.md).
;
; The second bank, and the cheapest possible one: its payload (src/complete.s,
; tab completion) is pure assembly whose state already lives in page 2, so there
; is no cc65 runtime to set up -- no C stack, no DATA to copy down, no BSS to
; clear. It takes NOTHING out of the program load area, unlike the disk bank's
; $9D70-$9FFF. That is why completion got its own bank rather than joining the
; disk bank: it would have inherited that bank's RAM cost for nothing.
;
; Bank ABI (bank_call in src/rbcp/launch.s):
;   $A000  "bnk"     identity
;   $A003  1         bank id -- checked, so a mis-numbered flash set is caught
;   $A004  jmp ...   entry table
;
; While this bank is served the base's whole BASIC half is gone, so the only
; resident code reachable is the KERNAL half: the published entry points
; ($FFD2 etc.) and the SVC table. _print_prompt is the interesting case -- see
; below.

.import _tab_complete
.import about_main
.import kbdiag_main

.segment "ENTRY"
        .byte "bnk", 1          ; $A000  identity: a bank, and WHICH bank
        jmp _tab_complete       ; $A004  entry 0: complete the word at the cursor
        jmp about_main          ; $A007  entry 1: the `about` text
        jmp kbdiag_main         ; $A00A  entry 2: the live keyboard matrix

; `about` rides in THIS bank rather than one of its own: it is self-contained
; assembly needing no cc65 runtime, exactly like the completion matcher, and
; this bank had 90% of its window free. It was the last RAM overlay -- moving it
; here retired that whole mechanism.

.segment "CODE"

; --- _print_prompt ----------------------------------------------------------
; complete.s reprints the prompt after listing candidates, and in the resident
; build that is shell.c's print_prompt(). We CANNOT call that here: it lives in
; the BASIC half, which is swapped out while this bank is served. (Nor could an
; SVC entry help -- the SVC table is only a row of JMPs, and a JMP into the
; swapped-out half lands in this bank's own code.)
;
; So the bank prints the prompt itself, from the device number and remembered
; name the resident side publishes in the $02D1 mailbox before calling. Defining
; it under the name complete.s already imports means complete.s moved into the
; bank with NO source changes, exactly like dir.c and fastload.c before it.
.export _print_prompt

CHROUT  = $FFD2
MB_DEV  = $02D1                 ; default device      (published by fs.c)
MB_NLEN = $02D2                 ; remembered name length
MB_NAME = $02D3                 ; remembered name

_print_prompt:
        ; device number, 1 or 2 digits (units are 8-15, but print generally)
        lda MB_DEV
        cmp #10
        bcc @units
        ldx #0
@tens:  cmp #10
        bcc @puttens
        sbc #10
        inx
        bne @tens
@puttens:
        pha
        txa
        clc
        adc #'0'
        jsr CHROUT
        pla
@units: clc
        adc #'0'
        jsr CHROUT

        ; ": <name>" when one is remembered
        lda MB_NLEN
        beq @sym
        lda #':'
        jsr CHROUT
        lda #' '
        jsr CHROUT
        ldx #0
@name:  cpx MB_NLEN
        bcs @sym
        lda MB_NAME,x
        jsr CHROUT
        inx
        bne @name

@sym:   lda #'>'                ; prompt_str in shell.c, always followed by a space
        jsr CHROUT
        lda #' '
        jmp CHROUT
