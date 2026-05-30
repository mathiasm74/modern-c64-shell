; ============================================================================
; fastload_recv.s -- host-side cycle-tight 2-bit receiver.
;
; Drive sends 4 bit-pairs per byte at 10us spacing (10 cycles on 1MHz CPU)
; via $1800 bits 3,1 (CLK out, DATA out). Host's $DD00 reads them: bit 6 =
; CLK in, bit 7 = DATA in. Drive pre-inverts each byte so the bus inversion
; cancels and the host's natural EOR-chain unscramble yields the byte.
;
; Per-byte handshake:
;   - Host pulls DATA low (READY edge); drive's @wait_ready exits.
;   - Host releases DATA after a short hold (GO edge); drive's @wait_go
;     exits and starts streaming the 4 pairs.
;
; SEI/PLP brackets the timed window. NMI is left enabled (no source armed).
; ============================================================================

.export _epyx_recv_byte
.export _epyx_recv_raw

CIA2_PRA = $DD00

.segment "CODE2"

; ----------------------------------------------------------------------------
; READY/GO handshake shared by both entry points. Expects to be called with
; the carry-set state irrelevant; preserves A on exit (so caller can fall
; into the timed read window immediately afterward).
; Calling convention: this is a macro, inlined into each entry point so the
; cycle count from "release STA" to "first LDA" is fixed and known.
; ----------------------------------------------------------------------------
.macro HANDSHAKE
        ; READY: pull DATA low. Drive's @wait_ready loop sees this.
        lda CIA2_PRA
        ora #$20                ; bit 5 = DATA out, 1 = assert low
        sta CIA2_PRA

        ; Hold DATA low long enough for drive's 9-cycle polling loop to
        ; catch the transition and advance to @wait_go.
        ldx #16
:       dex
        bne :-

        ; GO: release DATA. Drive's @wait_go falls through. From here:
        ;   bcc fall-through (2) + lda pair1 (4) + sta $1800 (4) = 10 cyc
        ; before pair 1 is on the bus. Worst case the drive's LDA-that-sees-
        ; DATA-high happens up to ~9 cycles after our STA completes (whole
        ; drive polling iteration), so total = ~19 cycles to pair 1 on bus.
        ; First host read should land in pair 1's window [19, 29].
        lda CIA2_PRA
        and #$DF
        sta CIA2_PRA            ; T = 0 here (release complete)
.endmacro


; ----------------------------------------------------------------------------
; epyx_recv_byte -- receive one byte; return A = byte.
; ----------------------------------------------------------------------------
_epyx_recv_byte:
        php
        sei

        HANDSHAKE

        ; T = 0 from end of release-STA. Pad N cycles, then LDA reads at
        ; cycle 4 of itself. For pair 1 read in window [19, 29], aim for
        ; read at T ~= 24.
        ;
        ; LDA reads at end of its 4-cyc instruction = at host T = pad + 4.
        ; Want pad + 4 ~= 24 → pad = 20 cyc → 10 NOPs.
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop

        ; --- EOR chain. Each step = LDA/EOR (4) + LSR (2) + LSR (2) + NOP (2) = 10 cyc.
        lda CIA2_PRA            ; pair 1 -> bits 6,7
        lsr
        lsr
        nop
        eor CIA2_PRA            ; pair 2
        lsr
        lsr
        nop
        eor CIA2_PRA            ; pair 3
        lsr
        lsr
        nop
        eor CIA2_PRA            ; pair 4 -> final byte

        ldx #0
        plp
        rts


; ----------------------------------------------------------------------------
; epyx_recv_raw -- read 4 $DD00 values at 10-cycle spacing and store to
; the buffer at $0370..$0373. Returns nothing useful; used for diagnostic.
; Calibration mirrors epyx_recv_byte so the same pad-NOPs apply.
; ----------------------------------------------------------------------------
_epyx_recv_raw:
        php
        sei

        HANDSHAKE

        ; Same pad as the production receiver.
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop

        ; --- Raw reads. LDA (4) + STA abs (4) + NOP (2) = 10 cyc.
        lda CIA2_PRA
        sta $0370               ; R1
        nop
        lda CIA2_PRA
        sta $0371               ; R2
        nop
        lda CIA2_PRA
        sta $0372               ; R3
        nop
        lda CIA2_PRA
        sta $0373               ; R4

        plp
        rts
