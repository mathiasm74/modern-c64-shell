; ============================================================================
; fastload_recv.s -- host-side Epyx 2-bit receiver (drive -> C64), Phase 7 step 3.
;
; The file download uses Meatloaf's transmitEpyxByte: the drive sends 4 bit-
; PAIRS per byte, ~10 us apart, all bits inverted on the wire. We signal "ready
; to send" by releasing DATA high; the drive then drives CLK+DATA and we sample
; $DD00 at +15/+25/+35/+45 cycles (CLK in = bit6, DATA in = bit7). The pairs map
; to the data bits as: pair1 (d7,d5), pair2 (d6,d4), pair3 (d3,d1), pair4 (d2,d0)
; -- so $DD00.bit6 carries ~d7/~d6/~d3/~d2 and $DD00.bit7 carries ~d5/~d4/~d1/~d0
; across the four samples. After the byte we pull DATA low ("got it").
;
; The 10-cycle inter-sample spacing is fixed by the protocol; the initial PAD
; (landing sample 1 in pair-1's window) is the one value that needs HARDWARE
; calibration -- use epyx_recv_raw to capture the four raw $DD00 reads and shift
; the pad until the samples line up. This direction can't be exercised in VICE
; (its 1541 has no Epyx transmit), so it is validated on real hardware.
;
; Per-byte handshake is via DATA only. The drive marks block boundaries by
; pulling CLK low ("not ready") and releasing it high ("ready"), so the block
; loop waits for that CLK low->high before each block's length byte.
; ============================================================================

.export _epyx_recv_byte, _epyx_recv_raw, _epyx_wait_ready

.import wait_clk_lo, wait_clk_hi

CIA2_PRA = $DD00
B_DATA   = $20          ; DATA output (1 = pull DATA low)

S0 = $02A8              ; four raw samples (unused page-3 KERNAL RAM)
S1 = $02A9
S2 = $02AA
S3 = $02AB
RES = $FB               ; assembled byte scratch (reset's boot pointer; free now)

.segment "CODE2"        ; KERNAL ROM half

; ----------------------------------------------------------------------------
; _epyx_wait_ready - wait for the drive's block "ready" signal: CLK goes low
; ("not ready", end of the previous block / opening the file) then high
; ("ready" with the next block). Returns A=0 on success, A=1 on timeout.
; ----------------------------------------------------------------------------
.proc _epyx_wait_ready
        jsr wait_clk_lo
        bcs @to
        jsr wait_clk_hi
        bcs @to
        lda #$00
        rts
@to:
        lda #$01
        rts
.endproc

; ----------------------------------------------------------------------------
; _epyx_recv_byte - receive one byte over the timed 2-bit protocol. Returns the
; byte in A (X=0). Masks IRQs across the timed window.
; ----------------------------------------------------------------------------
.proc _epyx_recv_byte
        php
        sei
        ; "ready to send": release DATA high. The drive starts its timed send.
        lda CIA2_PRA
        and #<~B_DATA
        sta CIA2_PRA                    ; T = 0 (DATA high)

        ; --- PAD: land sample 1 near +15 cycles. HARDWARE-CALIBRATE THIS. ---
        nop
        nop
        nop
        nop
        nop

        ; --- four samples, 10 cycles apart: LDA(4) + STA abs(4) + NOP(2) ---
        lda CIA2_PRA
        sta S0
        nop
        lda CIA2_PRA
        sta S1
        nop
        lda CIA2_PRA
        sta S2
        nop
        lda CIA2_PRA
        sta S3

        ; "got it": pull DATA low (drive's transmitEpyxByte waits for this).
        lda CIA2_PRA
        ora #B_DATA
        sta CIA2_PRA
        plp

        ; --- assemble (not time-critical). Shift each source bit into carry,
        ;     MSB first, and ROL it into RES. Bits arrive inverted, so the final
        ;     EOR #$FF restores the byte. $DD00.bit6 -> ASL,ASL; bit7 -> ASL.  ---
        lda S0
        asl a
        asl a
        rol RES                         ; d7 = ~S0.bit6
        lda S1
        asl a
        asl a
        rol RES                         ; d6 = ~S1.bit6
        lda S0
        asl a
        rol RES                         ; d5 = ~S0.bit7
        lda S1
        asl a
        rol RES                         ; d4 = ~S1.bit7
        lda S2
        asl a
        asl a
        rol RES                         ; d3 = ~S2.bit6
        lda S3
        asl a
        asl a
        rol RES                         ; d2 = ~S3.bit6
        lda S2
        asl a
        rol RES                         ; d1 = ~S2.bit7
        lda S3
        asl a
        rol RES                         ; d0 = ~S3.bit7

        lda RES
        eor #$FF                        ; wire bits were inverted
        ldx #$00
        rts
.endproc

; ----------------------------------------------------------------------------
; _epyx_recv_raw - timing diagnostic: same handshake + four samples as
; _epyx_recv_byte but stores the raw $DD00 reads to $0370..$0373 (and leaves
; them in S0..S3 too) instead of assembling. Use it to calibrate the PAD on
; hardware: with a known byte streaming, the four reads should show CLK/DATA
; (bits 6/7) carrying the expected inverted bit-pairs. void.
; ----------------------------------------------------------------------------
.proc _epyx_recv_raw
        php
        sei
        lda CIA2_PRA
        and #<~B_DATA
        sta CIA2_PRA                    ; T = 0

        nop
        nop
        nop
        nop
        nop

        lda CIA2_PRA
        sta $0370
        nop
        lda CIA2_PRA
        sta $0371
        nop
        lda CIA2_PRA
        sta $0372
        nop
        lda CIA2_PRA
        sta $0373

        lda CIA2_PRA
        ora #B_DATA
        sta CIA2_PRA
        plp
        rts
.endproc
