; kload_blob.s - the stock-KERNAL patch, carried in our ROM as plain data.
;
; build/kload.bin is linked separately (cfg/kload.cfg) to run at $F8E2 inside the
; served stock KERNAL. It cannot be linked into this image as code: it needs its
; own copies of the Epyx receiver/sender/clock-wait, which are already linked
; here under the same symbol names.
;
; It sits in our KERNAL half because that is what is still mapped when the swap
; trampoline runs -- and must be: the RBCP command page is at $E0xx, so the ROM
; is there by definition.

.export __KLOAD_IMG__, __KLOAD_IMG_SIZE__
.export __KLOAD2_IMG__, __KLOAD2_IMG_SIZE__
.export __KLOAD3_IMG__, __KLOAD3_IMG_SIZE__

.segment "KLOADIMG"

; Two pieces, because the tape space is two runs with live stock code between
; them: the code goes to $F8E2 and the tables to $FBA6 (cfg/kload.cfg).
__KLOAD_IMG__:
        .incbin "build/kload.bin"
__KLOAD_IMG_END__:

__KLOAD2_IMG__:
        .incbin "build/kload2.bin"
__KLOAD2_IMG_END__:

__KLOAD3_IMG__:
        .incbin "build/kload3.bin"
__KLOAD3_IMG_END__:

__KLOAD_IMG_SIZE__  = __KLOAD_IMG_END__ - __KLOAD_IMG__
__KLOAD2_IMG_SIZE__ = __KLOAD2_IMG_END__ - __KLOAD2_IMG__
__KLOAD3_IMG_SIZE__ = __KLOAD3_IMG_END__ - __KLOAD3_IMG__
