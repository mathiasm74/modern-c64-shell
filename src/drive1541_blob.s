; drive1541_blob.s - the drive-side loader as DATA in the disk bank's ROM.
;
; It is 6502 for the DRIVE's CPU, not ours, in two stages: the bootstrap
; (src/drive1541_boot.s, linked for $0400), which fastload.c M-W's up and M-E's,
; and the loader itself (src/drive1541.s, linked for $0500), which the bootstrap
; then clocks in over the fast path. Sizes travel with them, because the host
; loops need to know where to stop.
.export _drive1541_code, _drive1541_size
.export _drive1541_boot, _drive1541_boot_size

.segment "RODATA"

_drive1541_boot:
        .incbin "build/drive1541_boot.bin"
_drive1541_boot_end:

_drive1541_code:
        .incbin "build/drive1541.bin"
_drive1541_end:

; The bootstrap fetches exactly two pages and then jumps: a loader that grew
; past them would run with its tail missing.
.assert _drive1541_end - _drive1541_code <= $200, error, "drive1541.bin outgrew the bootstrap's two pages"

_drive1541_boot_size:
        .word _drive1541_boot_end - _drive1541_boot
_drive1541_size:
        .word _drive1541_end - _drive1541_code
