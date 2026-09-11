; kernal_shims.inc - C-callable shims over the fixed KERNAL entry points.
;
; Shared by the RAM overlays (crt0_dir.s et al, which run at $8800) and the
; DISK BANK (crt0_disk.s, served as ROM at $A000). Both are linked standalone --
; no shell symbol is visible to either -- so both reach the machine the same
; way, through the published KERNAL addresses. Extracted here when the disk
; cluster moved into a bank (docs/ROM-EXPANSION.md) so the two crt0s share one
; copy instead of drifting.
;
; Emitted into whatever segment is current at the point of inclusion.

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
