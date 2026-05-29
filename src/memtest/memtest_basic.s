; ============================================================================
; memtest_basic.s -- BASIC-bank test sentinels
;
; Hand-placed bytes at fixed BASIC ROM addresses, served via the OneROM BASIC
; chip-select. The KERNAL-resident test code (memtest.s) reads from these
; addresses and checks the values. Anywhere not covered here gets the BASIC
; fill sentinel ($5A) set in cfg/memtest.cfg's MEMORY block.
;
; Address  Bytes               Test
; -------  ------------------  ----------------------------------------------
; $A000    A0                  bank-ID low corner (A0-A12 all 0)
; $A050    55 AA 5A A5         transient-scan source ($55 expected; remaining
;                              3 bytes give a visible neighborhood if reads
;                              alias by a few bytes)
; $A100    01 02 04 08 10
;          20 40 80            walking-1 data bits
; $A200    FE FD FB F7 EF
;          DF BF 7F            walking-0 data bits
; $A800    A8                  exercises A11
; $B000    B0                  exercises A12
; $B800    B8                  exercises A11 + A12
; $BFFF    BF                  high corner (A0..A12 all 1)
; ============================================================================

.segment "MT_A000"
        .byte $A0

.segment "MT_A050"
        .byte $55, $AA, $5A, $A5

.segment "MT_A100"
        .byte $01, $02, $04, $08, $10, $20, $40, $80

.segment "MT_A200"
        .byte $FE, $FD, $FB, $F7, $EF, $DF, $BF, $7F

.segment "MT_A800"
        .byte $A8

.segment "MT_B000"
        .byte $B0

.segment "MT_B800"
        .byte $B8

.segment "MT_BFFF"
        .byte $BF
