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
; The 10-cycle inter-sample spacing is fixed by the protocol; the sample offsets
; (+14/24/34/44) are calibrated to this hardware -- see the note at the sampling
; code. This direction can't be exercised in VICE (its 1541 has no Epyx
; transmit), so it is validated on real hardware.
;
; Per-byte handshake is via DATA only. The drive marks block boundaries by
; pulling CLK low ("not ready") and releasing it high ("ready"), so the block
; loop waits for that CLK low->high before each block's length byte.
; ============================================================================

.export _epyx_recv_byte, _epyx_wait_ready

.import wait_clk_lo, wait_clk_hi

CIA2_PRA = $DD00
B_DATA   = $20          ; DATA output (1 = pull DATA low)
VIC_RASTER = $D012      ; VIC-II raster line (low 8 bits) -- for badline avoidance
YSCROLL  = $03          ; our $D011 = $1B, so badlines fall on (RASTER & 7) == 3

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
        ; Wait for the drive's "ready" = CLK high, held while transmitEpyxByte
        ; waits for our DATA-high. We do NOT wait for CLK low first: between
        ; blocks the drive's "not ready" CLK-low is too brief to catch (it pulls
        ; CLK low then immediately reads + raises CLK), and racing it deadlocked
        ; the transfer after one block. A brief settle lets the drive pull CLK
        ; low at the boundary so we don't latch a stale data-bit high; then we
        ; wait (retrying, to ride out a slow file lookup) for the held high.
        ldy #$10
@settle:
        dey
        bne @settle                     ; ~80 us
        ldx #$0A                         ; ~10 * 1.2s, covers a slow file lookup
@hi:
        jsr wait_clk_hi
        bcc @ok
        dex
        bne @hi
        lda #$01                         ; no "ready" (CLK high) -> give up
        rts
@ok:
        lda #$00
        rts
.endproc

; ----------------------------------------------------------------------------
; _epyx_recv_byte - receive one byte over the timed 2-bit protocol. Returns the
; byte in A (X=0). Masks IRQs across the timed window.
; ----------------------------------------------------------------------------
.proc _epyx_recv_byte
        php
        sei
        ; --- pause for VIC-II badlines instead of blanking the screen ---------
        ; The 4-pair sample below runs ~52 cycles on fixed timing; a badline
        ; (raster line where (RASTER & 7) == YSCROLL) stalls the CPU ~40 cycles
        ; and would corrupt the byte. The per-byte DATA handshake lets us stall
        ; first -- the drive blocks on our DATA-high -- so we hold until the
        ; raster sits at an offset from which the worst-case ~3-line window
        ; (read -> release -> last sample) can't touch the badline line. With
        ; YSCROLL=3, offsets {1,2,3} could straddle line 3; {0,4,5,6,7} are
        ; clear. The raster free-runs (independent of the CPU), so this always
        ; advances to a clear offset within a few lines. Inside the SEI so no
        ; IRQ perturbs the read->release->sample gap; screen stays visible.
@badline:
        lda VIC_RASTER
        and #$07
        beq @clear                      ; offset 0 -> clear
        cmp #(YSCROLL + 1)              ; offsets 1..3 -> still in the danger band
        bcc @badline                    ; wait it out (raster advances)
@clear:
        ; "ready to send": release DATA high. The drive starts its timed send.
        lda CIA2_PRA
        and #<~B_DATA
        sta CIA2_PRA                    ; T = 0 (DATA high)

        ; Sample the four bit-pairs at +14/24/34/44 (PAD 10, then 10-cyc gaps).
        ; This is the calibrated sweet spot for this hardware: the sampling
        ; window turned out to be narrow, and shifting either earlier (+9, reads
        ; the still-settling edge) or later (+28, reads the next pair) corrupts
        ; the byte. The drive writes the pairs ~0/17/27/37 us after it sees DATA
        ; high; this lands each read inside its pair's stable region.
        nop
        nop
        nop
        nop
        nop
        lda CIA2_PRA                    ; sample 1 (+14): ~d7/~d5
        sta S0
        nop
        lda CIA2_PRA                    ; sample 2 (+24): ~d6/~d4
        sta S1
        nop
        lda CIA2_PRA                    ; sample 3 (+34): ~d3/~d1
        sta S2
        nop
        lda CIA2_PRA                    ; sample 4 (+44): ~d2/~d0
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
