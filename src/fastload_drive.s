; ============================================================================
; fastload_drive.s -- 6502 code that runs in the 1541's RAM, not the C64's.
;
; Assembled with origin = $0500 (free buffer space behind buffers #1/#2 in
; the 1541's 2KB RAM). The host uploads this via M-W commands on the drive
; command channel, then M-Es it. M-E does a JSR into our entry point; the
; drive's command loop continues when we RTS.
;
; Phase 7b stub: just a sentinel writer so the host can prove that drive
; code is actually executing. fastload_install() M-Ws + M-Es this, then
; M-Rs the sentinel back. If the readback is $42, M-E works end-to-end.
;
; Future stages will grow this into the actual fast-send loop: drive-side
; sector read + the 2-bit timed protocol that streams the result over
; CLK/DATA on $1800 (the 1541's VIA1 controlling the IEC bus).
; ============================================================================

.segment "DRIVE_CODE"

drive_entry:
        lda #$42                ; "drive code ran" sentinel
        sta $07FF               ; top of the drive's RAM
        rts                     ; back to the drive's command loop
