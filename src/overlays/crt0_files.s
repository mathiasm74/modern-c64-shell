; crt0_files.s - startup + KERNAL shims for C overlays (tardis, backlog #4).
;
; Must be the FIRST object in the overlay link so the header lands at the
; overlay base ($8800):
;
;   +0  jmp start      entry point: the resident thunk calls the base address
;   +3  "fil1"         cache-validation magic: the thunk only trusts (and the
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

.import _files_main
.importzp sp
.import __OVL_START__, __OVL_LAST__

CSTACK_TOP = $A000

.segment "CODE"

        jmp start
        .byte "fil1"
        .byte <((__OVL_LAST__ - __OVL_START__ + $FF) / $100)
start:
        lda #<CSTACK_TOP
        sta sp
        lda #>CSTACK_TOP
        sta sp+1
        jsr _files_main
        rts

; --- KERNAL entry shims ----------------------------------------------------
; Overlays are linked standalone: no shell symbol is visible. The machine is
; reached through the fixed KERNAL entry points -- which is exactly why the
; shell keeps them at their published addresses.

KCHROUT = $FFD2
KGETIN  = $FFE4
KSETLFS = $FFBA
KSETNAM = $FFBD
KOPEN   = $FFC0
KCLOSE  = $FFC3
KCHKIN  = $FFC6
KCHKOUT = $FFC9
KCLRCHN = $FFCC
KCHRIN  = $FFCF

.export _k_chrout, _k_getin, _k_setlfs, _k_setnam, _k_open, _k_close
.export _k_chkin, _k_chkout, _k_clrchn, _k_chrin

.import popa, popax

; void __fastcall__ k_chrout(unsigned char c);
_k_chrout:
        jmp KCHROUT

; unsigned char k_getin(void);
_k_getin:
        jsr KGETIN
        ldx #0
        rts

; void __fastcall__ k_setlfs(unsigned char dev, unsigned char sa);
_k_setlfs:
        pha                     ; sa
        jsr popa                ; dev
        tax
        pla
        tay                     ; Y = sa
        lda #1                  ; LFN: always 1 (single-file model)
        jmp KSETLFS

; void __fastcall__ k_setnam(const char *name, unsigned char len);
_k_setnam:
        pha                     ; len
        jsr popax               ; A = name lo, X = name hi
        pha                     ; lo
        txa
        tay                     ; Y = name hi
        pla
        tax                     ; X = name lo
        pla                     ; A = len
        jmp KSETNAM

; unsigned char k_open(void);  returns 0 ok, error code otherwise
_k_open:
        jsr KOPEN
        bcs @err
        lda #0
@err:   ldx #0
        rts

; void k_close(void);
_k_close:
        lda #1                  ; LFN 1
        jmp KCLOSE

; unsigned char k_chkin(void);  0 = ok
_k_chkin:
        ldx #1
        jsr KCHKIN
        bcs @err
        lda #0
@err:   ldx #0
        rts

; unsigned char k_chkout(void);  0 = ok
_k_chkout:
        ldx #1
        jsr KCHKOUT
        bcs @err
        lda #0
@err:   ldx #0
        rts

; void k_clrchn(void);
_k_clrchn:
        jmp KCLRCHN

; unsigned char k_chrin(void);
_k_chrin:
        jsr KCHRIN
        ldx #0
        rts
