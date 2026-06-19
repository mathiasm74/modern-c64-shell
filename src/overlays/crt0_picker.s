; crt0_picker.s - startup + KERNAL shims for the color-picker overlay.
;
; Minimal C-overlay crt0 (cf. crt0_dir.s): the picker only needs CHROUT and
; GETIN. Must link FIRST so the header lands at the overlay base ($8800):
;   +0  jmp start    entry point the resident thunk calls
;   +3  "pic1"       cache-validation magic
;   +7  page count   total 256-byte pages (computed from the link symbols)

.export __STARTUP__ : absolute
__STARTUP__ = 1

.import _picker_main
.importzp sp
.import __OVL_START__, __OVL_LAST__

CSTACK_TOP = $A000

.segment "CODE"

        jmp start
        .byte "pic1"
        .byte <((__OVL_LAST__ - __OVL_START__ + $FF) / $100)
start:
        lda #<CSTACK_TOP
        sta sp
        lda #>CSTACK_TOP
        sta sp+1
        jsr _picker_main
        rts

KCHROUT = $FFD2
KGETIN  = $FFE4

.export _k_chrout, _k_getin

; void __fastcall__ k_chrout(unsigned char c);
_k_chrout:
        jmp KCHROUT

; unsigned char k_getin(void);
_k_getin:
        jsr KGETIN
        ldx #0
        rts
