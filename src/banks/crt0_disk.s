; crt0_disk.s - startup + KERNAL shims for the DISK BANK (docs/ROM-EXPANSION.md).
;
; A bank differs from a RAM overlay in two ways, and both land here:
;
;  1. It is SERVED as ROM at $A000, so there is no fetch and no cache magic --
;     the base just SWITCH_SLOTs the bank in and JSRs the $A000 JMP table. This
;     file must therefore be FIRST in the link so the table lands at $A000.
;  2. Its code is ROM, so writable state cannot live alongside it. cc65 DATA
;     (initialized writable globals) is linked load=ROM / run=RAM and copied
;     down by copydata at every entry; BSS and the C data stack are plain RAM
;     (cfg/disk_bank.cfg). Re-running copydata per entry is deliberate: a bank
;     is re-entered many times and whatever ran in between may have scribbled on
;     the RAM, exactly like an overlay re-initializing its own state.
;
; The C data stack points at $A000 and grows DOWN into $9Fxx RAM -- below the
; bank's ROM, so it never touches the served image. The bank's zeropage block
; ($40-$5F, per the cfg) is disjoint from the shell's ($02-$1F), so a bank call
; never disturbs the resident C state.
;
; cc65 force-imports __STARTUP__ from every C module; define it here as the
; overlay crt0s and reset.s do.

.export __STARTUP__ : absolute
__STARTUP__ = 1

.import _disk_dir, _disk_ls, _disk_pwd, _disk_fload
.import copydata
.importzp sp

CSTACK_TOP = $A000              ; grows down into $9Fxx RAM

; --- $A000 entry JMP table (the bank ABI) -----------------------------------
; bank_call (launch.s) JSRs $A000 + 3*entry after switching the served slot.
.segment "ENTRY"
        jmp e_dir               ; $A000  entry 0
        jmp e_ls                ; $A003  entry 1
        jmp e_pwd               ; $A006  entry 2
        jmp e_fload             ; $A009  entry 3

.segment "CODE"

e_dir:  jsr bank_init
        jmp _disk_dir           ; tail call: its RTS returns to bank_call
e_ls:   jsr bank_init
        jmp _disk_ls
e_pwd:  jsr bank_init
        jmp _disk_pwd
e_fload:
        jsr bank_init
        jmp _disk_fload

; Per-entry init: point the bank's own C stack at $A000 and copy DATA from ROM
; down to its RAM run location.
bank_init:
        lda #<CSTACK_TOP
        sta sp
        lda #>CSTACK_TOP
        sta sp+1
        jmp copydata            ; tail call; copydata RTSes to our caller

; --- KERNAL entry shims -----------------------------------------------------
; The bank is linked standalone, so the machine is reached through the fixed
; KERNAL entry points (which is exactly why we keep them at their published
; addresses) -- the same set, from the same source, the RAM overlays use.
.include "kernal_shims.inc"
