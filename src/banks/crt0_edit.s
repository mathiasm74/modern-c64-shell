; crt0_edit.s - entry layer for the EDIT BANK (docs/ROM-EXPANSION.md).
;
; Bank ABI (bank_call in src/rbcp/launch.s):
;   $A000  "bnk"     identity
;   $A003  3         bank id -- checked, so a mis-numbered flash set is caught
;   $A004  jmp ...   entry table
;
; The editor moved here from the $8800 RAM overlay because it outgrew that
; region (see cfg/edit_bank.cfg). Its DOCUMENT buffer is unaffected: that lives
; at $0800 in user RAM and always did. Only the editor's own code moved into
; served ROM, and its BSS/C stack into the shared bank RAM window.

.export __STARTUP__ : absolute
__STARTUP__ = 1

.import _edit_main
.import copydata, zerobss
.importzp sp

CSTACK_TOP = $A000              ; grows down into the bank RAM window

.segment "ENTRY"
        .byte "bnk", 3          ; $A000  identity: a bank, and WHICH bank
        jmp e_edit              ; $A004  entry 0

.segment "CODE"

e_edit: jsr bank_init
        jmp _edit_main

; Per-entry init: the bank's RAM is not its own between calls.
bank_init:
        lda #<CSTACK_TOP
        sta sp
        lda #>CSTACK_TOP
        sta sp+1
        jsr zerobss
        jmp copydata            ; tail call; copydata RTSes to our caller

.include "kernal_shims.inc"
