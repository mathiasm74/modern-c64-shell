; ============================================================================
; fastload_blob.s -- embed the drive-side image into the host ROM.
;
; build/fastload_drive.bin is the assembled drive-side code. We .incbin it
; into a const segment in the KERNAL ROM half (RODATA2) and expose two
; C-visible labels:
;
;   _fastload_drive_code      -- pointer to the first byte of the blob
;   _fastload_drive_code_size -- length in bytes (.word, so up to 65535)
;
; The host's fastload_install() reads these and ships them to the drive.
;
; This file just stitches the binary into our ROM image; no executable code
; here.
; ============================================================================

.export _fastload_drive_code
.export _fastload_drive_code_size

.segment "RODATA2"

_fastload_drive_code:
        .incbin "build/fastload_drive.bin"
_fastload_drive_code_end:

_fastload_drive_code_size:
        .word _fastload_drive_code_end - _fastload_drive_code
