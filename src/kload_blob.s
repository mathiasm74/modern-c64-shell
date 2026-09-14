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

.segment "KLOADIMG"

__KLOAD_IMG__:
        .incbin "build/kload.bin"
__KLOAD_IMG_END__:

__KLOAD_IMG_SIZE__ = __KLOAD_IMG_END__ - __KLOAD_IMG__
