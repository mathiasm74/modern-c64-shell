; fastload_send.s - host-side Epyx transmit (C64 -> drive), Phase 7 step 2.
;
; After the M-E $01A9 handshake (fastload_epyx_install) a Meatloaf drive runs
; its receiveEpyxHeader / receiveEpyxByte routines and clocks bytes IN from us.
; receiveEpyxByte waits for each CLK edge with no timeout -- the sender sets the
; pace -- so this whole direction is HANDSHAKED, not cycle-timed. Per byte the
; drive reads 8 bits, LSB first, inverted on DATA (DATA low = 1), sampling one
; bit per CLK edge with CLK alternating LOW, HIGH, ... starting LOW; after 8
; bits CLK is back HIGH, ready for the next byte. (The cycle-timed 2-bit
; protocol is the other direction -- the file download, step 3.)
;
; CIA #2 port A ($DD00), same conventions as src/iec.s: we DRIVE ATN (bit3
; $08), CLK (bit4 $10) and DATA (bit5 $20) -- writing a 1 pulls the open-
; collector line LOW. We READ CLK in on bit6 and DATA in on bit7.
;
; This direction can't be exercised in VICE (its 1541 doesn't implement
; Meatloaf's Epyx receive), so it is validated on real hardware together with
; the step-3 receiver. The logic is taken directly from Meatloaf's
; IECBusHandler.cpp::receiveEpyxByte.

DD00   = $DD00
B_ATN  = $08
B_CLK  = $10            ; CLK output (write 1 = pull CLK low)
B_DATA = $20            ; DATA output (write 1 = pull DATA low)

TMP    = $FB            ; byte being shifted out (reset's boot scratch; free now)
DDST   = $FC            ; our current $DD00 output bits (CLK/DATA we drive)

.import wait_clk_lo, wait_clk_hi
.export _epyx_send_begin, _epyx_send_byte, _epyx_send_end, _epyx_send_op

OPCNT = $FD            ; op-routine byte counter (reset boot scratch; free now)
OPSUM = $FE            ; the checksum byte to send last

; Segment: the KERNAL half normally, but the DISK BANK links this same source
; into its own image at $A000 (docs/ROM-EXPANSION.md), where CODE2 does not
; exist. One source, two homes -- see src/iec_clkwait.s for the same pattern.
.ifdef BANK_BUILD
.define CSEG "CODE"
.else
.define CSEG "CODE2"
.endif

.segment CSEG

; ---------------------------------------------------------------------------
; _epyx_send_begin - the "ready for header" handshake. The drive pulls CLK low
; to signal it is ready, we answer with DATA low, and the drive releases CLK.
; Masks IRQs for the whole transfer (keep the bus to ourselves). Returns A=0 on
; success; A=1 if the drive never signalled within the wait timeout (not in
; Epyx mode), with IRQs restored and the lines released. unsigned char.
; ---------------------------------------------------------------------------
.proc _epyx_send_begin
        sei
        lda DD00
        and #<~(B_ATN | B_CLK | B_DATA) ; release ATN/CLK/DATA: clean start
        sta DD00
        jsr wait_clk_lo                 ; drive pulls CLK low = "ready for header"
        bcs @fail
        lda DD00
        ora #B_DATA                     ; DATA low = "we are ready"
        sta DD00
        sta DDST                        ; remember state (DATA low, CLK high)
        jsr wait_clk_hi                 ; drive releases CLK = go
        bcs @fail
        lda #$00
        rts
@fail:
        lda DD00
        and #<~(B_CLK | B_DATA)         ; free the lines
        sta DD00
        cli
        lda #$01
        rts
.endproc

; ---------------------------------------------------------------------------
; _epyx_send_byte - clock the byte in A out to the drive: LSB first, each bit
; inverted on DATA, one bit per CLK edge with CLK alternating (LOW for bit 0).
; CLK is HIGH on entry and on exit. DATA is set valid before every CLK edge.
; void __fastcall__ (byte in A).
; ---------------------------------------------------------------------------
.proc _epyx_send_byte
        sta TMP
        ldx #$08
@bit:
        lda DDST
        and #<~B_DATA                   ; assume DATA high (a 0 bit)
        lsr TMP                         ; next bit (LSB) -> carry
        bcc @set
        ora #B_DATA                     ; a 1 bit -> DATA low (inverted)
@set:
        sta DDST
        sta DD00                        ; DATA now valid, CLK unchanged
        eor #B_CLK                      ; flip CLK to this bit's edge
        sta DDST
        sta DD00                        ; CLK edge: the drive samples DATA here
        dex
        bne @bit
        rts
.endproc

; ---------------------------------------------------------------------------
; _epyx_send_op - send the 256-byte "op routine" the drive expects before the
; header: 255 x $00 then the checksum byte (A). Meatloaf only sums and discards
; it, so the bytes are filler -- but the count and the sum must be exact. A tight
; ASM loop, no cc65 16-bit-counter loop per byte. fastcall: A = checksum.
; (OPCNT/OPSUM are disjoint from _epyx_send_byte's TMP/DDST at $FB/$FC.)
; ---------------------------------------------------------------------------
.proc _epyx_send_op
        sta OPSUM
        lda #255
        sta OPCNT
@l:     lda #$00
        jsr _epyx_send_byte             ; a filler $00
        dec OPCNT
        bne @l
        lda OPSUM
        jmp _epyx_send_byte             ; the checksum byte (tail call)
.endproc

; ---------------------------------------------------------------------------
; _epyx_send_end - hand the bus to the drive for the data download. Release CLK
; (the drive drives it now) but HOLD DATA low = "not ready": the drive's
; transmitEpyxByte parks on "wait for DATA high" with CLK held high, so the
; receiver can sync to that held CLK-high and only then release DATA (per byte)
; to start each timed transfer. Re-enables IRQs. void.
; ---------------------------------------------------------------------------
.proc _epyx_send_end
        lda DD00
        and #<~B_CLK                    ; release CLK
        ora #B_DATA                     ; hold DATA low ("not ready")
        sta DD00
        cli
        rts
.endproc
