; iec_clkwait.s - the IEC CLK-line waits, shared by the resident bus code and the
; DISK BANK.
;
; These used to live in iec.s. They moved out when the Epyx protocol moved into
; the disk bank (docs/ROM-EXPANSION.md): the bank is served at $A000 in place of
; the base BASIC half and cannot call into it, so the protocol's helpers must
; exist inside the bank image too. Rather than keep two copies of timing-relevant
; code in sync, the same source is linked into BOTH images and only the SEGMENT
; differs -- the main ROM puts them in KCODE (KERNAL half, which the bank shares
; byte-for-byte and so stays mapped), the bank in its own CODE at $A000.
;
; Callers jsr these directly rather than through the SVC table on purpose: the
; Epyx paths are cycle-counted, and an extra indirection is exactly the kind of
; jitter the receiver's badline pacing exists to avoid.

.ifdef BANK_BUILD
.segment "CODE"
.else
.segment "KCODE"
.endif

.export wait_clk_lo, wait_clk_hi

DD00   = $DD00
TMOUT  = $A6            ; receive-wait timeout countdown (KERNAL zp scratch, and
                        ; the same location the resident bus code uses -- the two
                        ; never run at once)

; Wait until CLK in is high / low, with a ~1.4s timeout. Carry clear once the
; line reaches the wanted state, carry set on timeout. The bound is generous
; because the talker may pause to read a disk sector; it exists only so a
; dead or disk-less drive can't wedge the shell. Clobbers A, X, Y, TMOUT.
;
; wait_clk_hi CONTRACT (relied on by iec_getbyte): on success (carry clear) the
; N flag holds DATA in ($DD00 bit 7) sampled by the same `bit DD00` that saw CLK
; go high -- the receive loop uses that instead of a separate read, so there's
; no edge-to-sample gap for a badline to corrupt. Keep @ok flag-preserving
; (clc/rts) so N survives.
wait_clk_hi:
        lda #$02
        sta TMOUT
@z:     ldx #$00
@x:     ldy #$00
@y:     bit DD00
        bvs @ok                 ; CLK high
        dey
        bne @y
        dex
        bne @x
        dec TMOUT
        bne @z
        sec                     ; timed out
        rts
@ok:    clc
        rts
wait_clk_lo:
        lda #$02
        sta TMOUT
@z:     ldx #$00
@x:     ldy #$00
@y:     bit DD00
        bvc @ok                 ; CLK low
        dey
        bne @y
        dex
        bne @x
        dec TMOUT
        bne @z
        sec
        rts
@ok:    clc
        rts
