; drive1541_blob.s - the drive-side loader as DATA in the disk bank's ROM.
;
; It is 6502 for the DRIVE's CPU, not ours: linked by cfg/drive1541.cfg to run
; at $0500 in drive RAM and carried here only so fastload.c can M-W it up. The
; size travels with it, because the host loop needs to know where to stop.
.export _drive1541_code, _drive1541_size

.segment "RODATA"

_drive1541_code:
        .incbin "build/drive1541.bin"
_drive1541_end:

_drive1541_size:
        .word _drive1541_end - _drive1541_code
