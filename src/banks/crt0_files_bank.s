; crt0_files_bank.s - entry layer for the FILES BANK (docs/ROM-EXPANSION.md).
;
; Bank ABI (bank_call in src/rbcp/launch.s):
;   $A000  "bnk"     identity
;   $A003  2         bank id -- checked, so a mis-numbered flash set is caught
;   $A004  jmp ...   entry table, one entry per command
;
; Like the disk bank this carries cc65 C, so each entry re-initializes the
; bank's RAM (BSS, DATA, C stack) before running: a bank's RAM is not its own
; between calls. That RAM is the SAME window the disk bank uses -- only one bank
; is served at a time, so they share it and adding a bank costs no further
; program space.

.export __STARTUP__ : absolute
__STARTUP__ = 1

.import _fb_cat, _fb_less, _fb_cp, _fb_mv, _fb_rm, _fb_status, _fb_cd
.import _fb_border, _fb_bg, _fb_text, _fb_peek, _fb_poke, _fb_help
.import _fb_device, _fb_devices, _fb_identify
.import copydata, zerobss
.importzp sp

CSTACK_TOP = $A000              ; grows down into $9Exx/$9Fxx RAM

.segment "ENTRY"
        .byte "bnk", 2          ; $A000  identity: a bank, and WHICH bank
        jmp e_cat               ; $A004  entry 0
        jmp e_less              ; $A007  entry 1
        jmp e_cp                ; $A00A  entry 2
        jmp e_mv                ; $A00D  entry 3
        jmp e_rm                ; $A010  entry 4
        jmp e_status            ; $A013  entry 5
        jmp e_cd                ; $A016  entry 6
        ; border/bg/text were entries 7-9. They moved to the UTIL BANK along
        ; with the colour picker they open -- a bank cannot call another bank, so
        ; the picker has to live in the same image as the commands that open it,
        ; and this bank was at 97% while that one was at 29%. Everything after
        ; them renumbered; shell.c's dispatch rows and fs.c's identify index are
        ; the two places that encode these numbers.
        jmp e_peek              ; $A019  entry 7
        jmp e_poke              ; $A01C  entry 8
        jmp e_help              ; $A01F  entry 9
        jmp e_device            ; $A022  entry 10
        jmp e_devices           ; $A025  entry 11
        jmp e_identify          ; $A028  entry 12 (boot-time, not a command)

.segment "CODE"

e_cat:      jsr bank_init
            jmp _fb_cat
e_less:     jsr bank_init
            jmp _fb_less
e_cp:       jsr bank_init
            jmp _fb_cp
e_mv:       jsr bank_init
            jmp _fb_mv
e_rm:       jsr bank_init
            jmp _fb_rm
e_status:   jsr bank_init
            jmp _fb_status
e_cd:       jsr bank_init
            jmp _fb_cd
e_peek:     jsr bank_init
            jmp _fb_peek
e_poke:     jsr bank_init
            jmp _fb_poke
e_help:     jsr bank_init
            jmp _fb_help
e_device:   jsr bank_init
            jmp _fb_device
e_devices:  jsr bank_init
            jmp _fb_devices
e_identify: jsr bank_init
            jmp _fb_identify

; Per-entry init: point the bank's C stack at the top of its RAM window, clear
; BSS and copy DATA down from ROM. Both run on EVERY entry because the shell, a
; loaded program, or another bank may have used that RAM in between.
bank_init:
        lda #<CSTACK_TOP
        sta sp
        lda #>CSTACK_TOP
        sta sp+1
        jsr zerobss
        jmp copydata            ; tail call; copydata RTSes to our caller

; --- KERNAL entry shims -----------------------------------------------------
; The bank is linked standalone, so the machine is reached through the fixed
; KERNAL entry points -- the same source the RAM overlays use.
.include "kernal_shims.inc"
