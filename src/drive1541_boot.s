; ============================================================================
; drive1541_boot.s - the stage-1 BOOTSTRAP for src/drive1541.s.
;
; Uploading the whole loader with M-W cost 1.5 s a load: the command channel
; moves ~2.4 ms a byte, and 492 bytes of it is 15 transactions. So only THIS
; goes up by M-W -- small enough for three -- and it is M-E'd at $0400. It then
; clocks the real loader in over the fast host->drive path, two pages straight
; to $0500-$06FF, and jumps to it. That is how the cartridge gets its drive code
; up too; the code is ours.
;
; THE WIRE is the host's existing Epyx transmit (src/fastload_send.s, the path a
; Meatloaf receives the filename on), so the host needed nothing new:
;   start:  we pull CLK low ("ready"); the host answers DATA low; we release
;           CLK ("go").
;   a bit:  the host sets DATA, THEN moves CLK -- low for bits 0/2/4/6, high for
;           1/3/5/7 -- so each CLK level change says "DATA is valid now".
;           LSB first; DATA LOW = 1.
; The host sets the pace and nothing on this side is timed: a host that stalls
; (a badline, an IRQ) is only a slower host. What IS fixed is that this loop
; must look at the wire at least once per CLK level, and the host holds each
; one ~34 cycles against our ~23 from read to read. Interrupts are off for the
; whole receive -- the controller's IRQ would stretch that past a level.
;
; DATA is taken from the SAME $1800 read that sees the CLK edge. The host set it
; ~9 cycles before the edge and holds it ~25 after, so a read that catches the
; edge, however late in the poll, always has a settled DATA bit.
;
; It takes EXACTLY the loader's length, which the Makefile passes in as LDRSIZE
; (the size of build/drive1541.bin), so the host sends no padding.
;
; Line polarity as in src/drive1541.s: every $1800 bit reads 1 when the line is
; LOW -- bit 0 DATA in, bit 2 CLK in; bit 3 is CLK out (1 = pull low).
; ============================================================================

VIA2    = $1800
D_CIN   = $04
D_COUT  = $08
LOADER  = $0500                 ; where src/drive1541.s runs
LDREND  = LOADER + LDRSIZE

; Two pages at most: $0700 is buffer 4, which holds the BAM.
.assert LDREND <= $0700, error, "drive1541.bin would overwrite the BAM at $0700"

.segment "DRIVEBOOT"

boot:
        sei
        lda #D_COUT
        sta VIA2                ; CLK low: "ready"
@host:  lda VIA2
        lsr a
        bcc @host               ; wait for the host's DATA low
        lda #$00
        sta VIA2                ; release CLK: "go"
        tay                     ; Y = the byte's offset in the page

@byte:  lda #$80                ; SENTINEL: eight RORs walk it out into the
        sta v_byte              ; carry exactly when the byte is complete
@pair:
@lo:    ldx VIA2                ; 4   wait for CLK LOW -- an even bit
        txa                     ; 2
        and #D_CIN              ; 2
        beq @lo                 ; 3
        txa                     ; 2   DATA from the same read
        lsr a                   ; 2   carry = DATA in: 1 = LOW = a 1 bit
        ror v_byte              ; 6
@hi:    ldx VIA2                ; 4   wait for CLK HIGH -- an odd bit
        txa                     ; 2
        and #D_CIN              ; 2
        bne @hi                 ; 3
        txa                     ; 2
        lsr a                   ; 2
        ror v_byte              ; 6   the sentinel reaches the carry on bit 7
        bcc @pair               ; 3

        lda v_byte
@store: sta LOADER,y            ; the page byte is patched as we go
        iny
        bne @end
        inc @store+2
@end:   cpy #<LDREND
        bne @byte
        lda @store+2
        cmp #>LDREND
        bne @byte
        jmp LOADER              ; its rts returns to the DOS, as the M-E would

v_byte: .byte 0
