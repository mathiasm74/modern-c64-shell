; crt0_dir.s - startup + KERNAL shims for C overlays (tardis, backlog #4).
;
; Must be the FIRST object in the overlay link so the header lands at the
; overlay base ($8800):
;
;   +0  jmp start      entry point: the resident thunk calls the base address
;   +3  "dir1"         cache-validation magic: the thunk only trusts (and the
;                      VICE tests pre-seed) a cache whose magic matches, so a
;                      `load`ed program that clobbered user RAM forces a
;                      refetch instead of a jump into garbage
;   +7  page count     total 256-byte pages of this overlay's file image; the
;                      thunk fetches page 1, reads this, then fetches the rest
;
; start points the overlay's OWN cc65 data stack (sp, in the overlay's own
; zeropage block per overlay_edit.cfg) at $A000 and calls the C main. The
; shell's C state is untouched: disjoint zp, disjoint stack.
;
; cc65 force-imports __STARTUP__ from every C module; define it here like
; reset.s does for the shell.

.export __STARTUP__ : absolute
__STARTUP__ = 1

.import _dir_main
.importzp sp
.import __OVL_START__, __OVL_LAST__

CSTACK_TOP = $A000

.segment "CODE"

        jmp start
        .byte "dir1"
        .byte <((__OVL_LAST__ - __OVL_START__ + $FF) / $100)
start:
        lda #<CSTACK_TOP
        sta sp
        lda #>CSTACK_TOP
        sta sp+1
        jsr _dir_main
        rts

.include "kernal_shims.inc"
