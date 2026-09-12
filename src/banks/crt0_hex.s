; crt0_hex.s - entry layer for the HEX BANK (docs/ROM-EXPANSION.md).
;
; Bank ABI (bank_call in src/rbcp/launch.s):
;   $A000  "bnk"     identity
;   $A003  3         bank id -- checked, so a mis-numbered flash set is caught
;   $A004  jmp ...   entry table
;
; A byte editor, written for this shell rather than ported: it uses the KERNAL
; shims and the resident PETSCII display helper (svc 12), so it carries no
; screen or formatting library of its own. Its DOCUMENT lives at $0800 in user
; RAM, like the text editor's; only code is served ROM.

.export __STARTUP__ : absolute
__STARTUP__ = 1

.import _hex_main
.import copydata, zerobss
.importzp sp

CSTACK_TOP = $A000              ; grows down into the bank RAM window

.segment "ENTRY"
        .byte "bnk", 4          ; $A000  identity: a bank, and WHICH bank
        jmp e_hex              ; $A004  entry 0

.segment "CODE"

e_hex: jsr bank_init
        jmp _hex_main

; Per-entry init: the bank's RAM is not its own between calls.
bank_init:
        lda #<CSTACK_TOP
        sta sp
        lda #>CSTACK_TOP
        sta sp+1
        jsr zerobss
        jmp copydata            ; tail call; copydata RTSes to our caller

.include "kernal_shims.inc"
