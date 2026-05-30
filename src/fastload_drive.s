; ============================================================================
; fastload_drive.s -- 6502 code that runs in the 1541's RAM, not the C64's.
;
; Assembled with origin $0500 (free buffer space behind buffers #1/#2). Host
; uploads via M-W on the drive command channel, then M-Es a specific entry.
;
; Entry table (host M-Es one of these addresses):
;   $0500  drive_sentinel  -- Phase 7b: write $42 to $07FF, RTS (M-E sanity)
;   $0503  drive_one_byte  -- Phase 7c2: send a single byte ($42) via the
;                             2-bit timed protocol, then RTS
;   $0506  drive_counter   -- Phase 7c3 (reserved)
;
; --- 2-bit protocol (our variant, NOT bit-compatible with the Epyx cart) ---
;
; We don't have to be Epyx-compatible since we own both ends. The original
; cart's pair mapping {(7,5)(6,4)(3,1)(2,0)} required the drive to
; pre-permute each byte for the host's natural EOR-chain unscramble to
; recover the original; we use the simpler mapping where pair K transmits
; consecutive bits (2K-2, 2K-1) of ~byte, which the host's standard EOR
; chain reconstructs as `byte` directly.
;
;   pair 1: CLK = (~B)[0],  DATA = (~B)[1]
;   pair 2: CLK = (~B)[2],  DATA = (~B)[3]
;   pair 3: CLK = (~B)[4],  DATA = (~B)[5]
;   pair 4: CLK = (~B)[6],  DATA = (~B)[7]
;
; Drive writes 1 to $1800 bit 3 (CLK out) to assert line low; the line
; inversion turns each "1 sent" into a "0 read" at the host's $DD00.
; Sending ~B compensates for that, so the host's read of CIA bit 6
; equals the original B's bit value.
;
; Per-byte sync handshake:
;   - Drive releases both CLK and DATA (writes 0 to $1800 bits 1/3).
;   - Drive polls $1800 bit 0 (DATA in); loops while DATA-in is low.
;     The host pulls DATA low to mean "not ready"; releasing it to high
;     is the "go" signal.
;   - On go, drive writes the 4 pair values to $1800 with 10-cycle
;     spacing (LDA abs / STA abs / NOP = 10 cycles), matching the
;     standard ~10us Epyx-on-1MHz timing.
;
; ZP scratch ($80-$84): 1541's lower ZP is owned by stock DOS up to ~$7F;
; $80-$FF is free for our routine.
;
; Absolute scratch ($0600-$0603): the 4 precomputed pair values. Putting
; these in absolute (LDA abs = 4 cycles) instead of ZP (3 cycles) makes
; LDA + STA $1800 + NOP land exactly on the 10-cycle target.
; ============================================================================

zp_byte = $80
zp_inv  = $81
zp_via  = $82
zp_tmp  = $83

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
        ; No startup delay -- epyx_send_byte's @wait_ready handshake blocks
        ; the drive until the host signals readiness by pulling DATA low.
        ; A fixed delay would either be too short (drive sends before host
        ; reads) or too long (host hangs in its DATA-low wait).
        lda #$42
        jsr epyx_send_byte

        ; After the byte: pull CLK low as a 'transfer done' handshake.
        lda $1800
        ora #$08                ; CLK out = bit 3
        sta $1800
        rts

; ----------------------------------------------------------------------------
; epyx_send_byte -- send one byte via the 2-bit timed protocol.
; In:  A = byte to send
; Out: lines hold pair-4 state on exit; the next call's release step
;      resets them.
; Cost: ~140 cycles total (precompute ~80 + sync wait + 40-cyc cycle-tight).
; ----------------------------------------------------------------------------
epyx_send_byte:
        sta zp_byte
        eor #$FF
        sta zp_inv              ; ~B (drive sends inverted bits)

        ; Base $1800: preserve all bits except CLK out (bit 3) and DATA
        ; out (bit 1), which the pair values will OR in.
        lda $1800
        and #$F5
        sta zp_via

        ; ---- Precompute the 4 pair values ----
        ; Each pair: bit a of zp_inv lands at VIA bit 3 (CLK out),
        ; bit b lands at VIA bit 1 (DATA out). Bit positions in zp_inv
        ; differ per pair so each gets a tailored AND-shift sequence.

        ; Pair 1: (zp_inv)[0] -> bit 3 ; (zp_inv)[1] -> bit 1
        lda zp_inv
        and #$02                ; bit 1 already at position 1
        sta zp_tmp
        lda zp_inv
        asl
        asl
        asl                     ; bit 0 -> bit 3
        and #$08
        ora zp_tmp
        ora zp_via
        sta pair1

        ; Pair 2: (zp_inv)[2] -> bit 3 ; (zp_inv)[3] -> bit 1
        lda zp_inv
        asl                     ; bit 2 -> bit 3
        and #$08
        sta zp_tmp
        lda zp_inv
        lsr
        lsr                     ; bit 3 -> bit 1
        and #$02
        ora zp_tmp
        ora zp_via
        sta pair2

        ; Pair 3: (zp_inv)[4] -> bit 3 ; (zp_inv)[5] -> bit 1
        lda zp_inv
        lsr                     ; bit 4 -> bit 3
        and #$08
        sta zp_tmp
        lda zp_inv
        lsr
        lsr
        lsr
        lsr                     ; bit 5 -> bit 1
        and #$02
        ora zp_tmp
        ora zp_via
        sta pair3

        ; Pair 4: (zp_inv)[6] -> bit 3 ; (zp_inv)[7] -> bit 1
        lda zp_inv
        lsr
        lsr
        lsr                     ; bit 6 -> bit 3
        and #$08
        sta zp_tmp
        lda zp_inv
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr                     ; bit 7 -> bit 1
        and #$02
        ora zp_tmp
        ora zp_via
        sta pair4

        ; ---- Two-edge handshake with the host ----
        ; First release CLK and DATA so we can read DATA-in.
        lda zp_via
        sta $1800

        ; Settle then wait for host's READY signal: DATA in goes LOW.
        ; (Host pulls DATA low to say 'I'm in my receive code'.)
        nop
        nop
@wait_ready:
        lda $1800
        lsr                     ; DATA in (bit 0) -> carry
        bcs @wait_ready         ; loop while DATA in is high (host idle)

        ; Host is ready. Now wait for the GO edge: DATA goes HIGH again
        ; (host released DATA = "send now"). Host calibrates its first
        ; read against this release.
@wait_go:
        lda $1800
        lsr
        bcc @wait_go            ; loop while DATA in low (still asserted)

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
