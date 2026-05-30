; ============================================================================
; fastload_drive.s -- 6502 code that runs in the 1541's RAM, not the C64's.
;
; Assembled with origin $0500 (free buffer space behind buffers #1/#2). Host
; uploads via M-W on the drive command channel, then M-Es a specific entry.
;
; Entry table (host M-Es one of these addresses):
;   $0500  drive_sentinel  -- Phase 7b: write $42 to $07FF, RTS (M-E sanity)
;   $0503  drive_one_byte  -- Phase 7c1: send a single byte ($42) via the
;                             2-bit Epyx-style timed protocol, then RTS
;   $0506  drive_counter   -- Phase 7c3 (reserved): send 0..255 in sequence
;
; The 2-bit protocol (sender side):
;   - Per byte: release CLK and DATA, then loop until DATA-in goes high
;     (host's "go" signal -- host pulls DATA low to mean "not ready").
;   - Drive writes 4 pairs to $1800 with 10-cycle spacing on the 6502.
;     Pair K places one byte bit on CLK-out (bit 3) and one on DATA-out
;     (bit 1) per the SD2IEC mapping {CLK=7,6,3,2 / DATA=5,4,1,0}.
;   - Lines remain in pair-4 state until the next send sets them.
;
; ZP scratch ($80-$85): 1541's lower ZP is owned by stock DOS up to ~$7F;
; $80-$FF is free for our routine.
;
; Absolute scratch ($0600-$0603): the 4 precomputed pair values, written
; to $1800 in the cycle-tight send. Putting these in absolute rather than
; ZP makes LDA take 4 cycles instead of 3 -- with STA abs (4) + NOP (2)
; that's 10 cycles per pair, exactly the 10us Epyx target on a 1MHz CPU.
; ============================================================================

zp_byte = $80
zp_via  = $81

pair1   = $0600
pair2   = $0601
pair3   = $0602
pair4   = $0603


.segment "DRIVE_CODE"

; --- Entry table at the head of the blob ---
        jmp drive_sentinel      ; $0500
        jmp drive_one_byte      ; $0503

; --- $0506+: routine bodies ---

drive_sentinel:
        lda #$42
        sta $07FF
        rts

drive_one_byte:
        ; Initial settle: 256 * 5 cycles = ~1.3ms. Gives the host plenty of
        ; time after M-E to land in its own SEI'd receive routine before we
        ; start clocking the byte out. Without this the drive's send would
        ; race the host's setup, and the first pair-1 might be missed.
        ldx #0
@dly:   dex
        bne @dly

        lda #$42
        jsr epyx_send_byte

        ; After the byte: pull CLK low as the "transfer done" handshake.
        ; Epyx uses CLK-low between transfers; our host doesn't watch it yet
        ; but this keeps us protocol-shaped for future expansion.
        lda $1800
        ora #$08                ; CLK out = bit 3
        sta $1800
        rts

; ----------------------------------------------------------------------------
; epyx_send_byte -- send one byte via the 2-bit timed protocol.
; In:  A = byte to send
; Out: lines are in the pair-4 state on exit; caller is responsible for
;      resetting them if needed (next call resets via its release step).
; Cost: ~80 cycles total (precompute + sync + send).
; ----------------------------------------------------------------------------
epyx_send_byte:
        sta zp_byte

        ; Base $1800 value: preserve everything except CLK-out (bit 3) and
        ; DATA-out (bit 1), which we'll OR in per pair.
        lda $1800
        and #$F5
        sta zp_via

        ; ---- Precompute the 4 pair values ----
        ; Each pair: CLK source bit ends up in bit 3, DATA source bit in bit 1,
        ; everything else from zp_via.

        ; Pair 1: CLK=bit7, DATA=bit5. After AND #$A0 + 4 LSRs:
        ;   $A0 = 1010_0000 -> 0101_0000 -> 0010_1000 -> 0001_0100 -> 0000_1010
        ; bits land at positions 3, 1.
        lda zp_byte
        and #$A0
        lsr
        lsr
        lsr
        lsr
        ora zp_via
        sta pair1

        ; Pair 2: CLK=bit6, DATA=bit4. AND #$50 + 3 LSRs.
        lda zp_byte
        and #$50
        lsr
        lsr
        lsr
        ora zp_via
        sta pair2

        ; Pair 3: CLK=bit3, DATA=bit1. AND #$0A -- bits already at 3,1.
        lda zp_byte
        and #$0A
        ora zp_via
        sta pair3

        ; Pair 4: CLK=bit2, DATA=bit0. AND #$05 + 1 ASL.
        lda zp_byte
        and #$05
        asl
        ora zp_via
        sta pair4

        ; ---- Release CLK and DATA (both high), then wait for host go ----
        lda zp_via
        sta $1800

        ; Tiny settle so the bus drivers see the release before we sample.
        nop
        nop

@wait:  lda $1800
        lsr                     ; DATA-in (bit 0) -> carry
        bcc @wait               ; loop while host holds DATA low

        ; ---- Cycle-tight send: 10 cycles per pair ----
        ; LDA abs (4) + STA abs (4) + NOP (2) = 10 cycles.
        lda pair1
        sta $1800
        nop
        lda pair2
        sta $1800
        nop
        lda pair3
        sta $1800
        nop
        lda pair4
        sta $1800

        rts
