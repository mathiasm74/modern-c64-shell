; ============================================================================
; drive1541.s - the DRIVE half of the fast loader, for a drive that really
; runs 6502: a stock 1541, a Pi1541, a 1541 Ultimate.
;
; Uploaded with M-W and started with M-E, after which it owns the machine and
; never returns. It finds a file, walks its sector chain and ships it to the
; host with the same wire protocol src/fastload_recv.s already speaks:
;
;   per block:  CLK low ("not ready") -> CLK high ("ready")
;               length byte, then `length` data bytes, back to back
;               a ZERO length block means end of file
;   per byte:   wait for the host to release DATA ("ready"); that edge is T=0
;               write four CLK/DATA pairs at T = 0 / 17 / 27 / 37
;                   pair 1 = d7,d5   pair 2 = d6,d4
;                   pair 3 = d3,d1   pair 4 = d2,d0
;               release, then wait for the host to pull DATA low ("got it")
;   the host samples at T = 14 / 24 / 34 / 44, i.e. mid-pair.
;
; WHY THIS EXISTS. Our other payload is 75 bytes of $EA whose checksums match
; what a Meatloaf fingerprints; Meatloaf never executes it and answers with its
; own native implementation. A drive that genuinely executes what it is sent
; needs genuine code, and had none -- so every real 1541 fell back to stock
; speed (and, before the probe was wired into `fload`, hung on the M-E).
;
; NOT Epyx's code. We own both ends of this wire, so the protocol is all we had
; to match; the implementation is ours, which also keeps it clear of a
; commercial cartridge's ROM. The Meatloaf path is untouched and still ships
; the fingerprint -- the probe picks between them.
;
; LINE POLARITY, read out of the drive ROM rather than assumed
; (dos1541-325302-01+901229-05, $E99C / $E9A5 / $E9C9):
;   $1800 bit 0  DATA in    1 = the line is LOW
;   $1800 bit 1  DATA out   1 = PULL LOW   ($E9A5 ora #$02 = "DATA low")
;   $1800 bit 2  CLK in     1 = the line is LOW
;   $1800 bit 3  CLK out    1 = PULL LOW   ($E9C9 lda #$08 = the CLK bit)
;
; THE INPUTS ARE INVERTED TOO -- 1 means the line is pulled LOW, not released.
; The bus transceivers invert in both directions, so "1 = low" is the rule for
; all four bits, not just the outputs. Assuming the inputs read the line state
; the way a C64's $DD00 does puts every handshake in this file backwards, and
; it fails in a way that looks like a timing problem rather than a polarity
; one: the drive waits for "released" while the host is holding the line down,
; wakes on the host's "got it" instead of its "ready", and writes its four
; pairs just after the host has finished sampling. Measured, not assumed --
; the host folded $FF (all four samples identical, i.e. nobody driving) while
; the drive had entered send_byte once and never left it.
; ============================================================================

VIA2     = $1800
D_DIN    = $01
D_DOUT   = $02
D_CIN    = $04
D_COUT   = $08
D_LINES  = D_DOUT | D_COUT

; The disk controller's job queue. Buffer 0: write the track/sector and a job
; code, and the controller (which runs under IRQ, so interrupts must be ON
; while we wait) does the read and leaves the data at $0300.
JOBCODE  = $00
JOBTRK   = $06
JOBSEC   = $07
BUF      = $0300
READJOB  = $80

ERR_ID   = $0B                  ; job result: header ID != the mounted ID
DISKID   = $12                  ; the ID the controller expects ($12/$13)
HDRID    = $16                  ; the ID in the header it last read ($16/$17)

VIA2T1CH = $1C05                ; the controller tick: T1 counter high
VIA2T1LH = $1C07                ; ... and latch high

DIR_TRK  = 18
DIR_SEC  = 1

; NO ZERO PAGE. The first attempt kept state in $50-$5F on the theory that it
; was finished command-scratch; it is not -- the value 18 written to the track
; byte read back as 0, because the DOS and the disk controller's IRQ are still
; using that page. Everything lives in our own block instead, addressed
; absolutely, and the sector buffer is walked with absolute,X rather than
; (zp),y so no zero page is needed at all. It costs a cycle per access and only
; the four timed stores care, which are padded to match.

.segment "DRIVECODE"

; ---------------------------------------------------------------------------
; A FIXED header, so the host needs no symbols out of this build: a jump at the
; load address, then the filename. The host M-W's the name here before the M-E,
; which is why the drive never has to RECEIVE anything -- the fast path is
; one-directional, which is the half that matters for speed and much the harder
; half to get right.
;
;   $0500  jmp entry        <- the M-E target
;   $0503  name length
;   $0504  name, 16 bytes
; ---------------------------------------------------------------------------
        jmp entry
fname_len:
        .byte 0
fname:
        .res 16, 0

; Our state lives in BSS, after the code: none of it needs an initial value,
; so none of it needs uploading -- the bootstrap stops at the end of the code.
.segment "DRIVEBSS"
v_trk:   .byte 0                ; the sector we are reading
v_sec:   .byte 0
v_cnt:   .byte 0                ; data bytes in this block
v_base:  .byte 0                ; $1800 with both line bits cleared
v_last:  .byte 0                ; last Y of the block's data
v_ent:   .byte 0                ; directory entry offset while searching
v_try:   .byte 0                ; read_sector's attempts left

.segment "DRIVECODE"

; ---------------------------------------------------------------------------
entry:
        cld
        ; CLK LOW means "not ready", and it has to go low HERE -- before the
        ; directory search, which takes milliseconds.
        ;
        ; Releasing both lines instead (what this did first) leaves CLK HIGH,
        ; which IS the ready signal. The host, already sitting in
        ; _epyx_wait_ready, was therefore satisfied the instant it looked:
        ; it released DATA, sampled an idle bus, pulled DATA low and gave up
        ; on a zero-length block -- all while this code was still reading
        ; sectors. Traced from the drive side: 256 consecutive samples of
        ; $1800 read a completely static $00, because by the time we reached
        ; the send the host had long since finished.
        lda VIA2
        and #<~D_DOUT           ; DATA released
        ora #D_COUT             ; CLK low = "not ready"
        sta VIA2

        jsr find_file
        bcc @found
        ; Not found, or a read error: hand the host an immediate end of file.
        ; It reports "fast load failed" and falls back, which is the right
        ; answer -- better than leaving it waiting on a drive that has nothing.
        jmp @stop
@found:
        ; v_trk/v_sec now hold the file's first sector.
@chain:
        jsr read_sector
        bcs @stop
        ; Link bytes: track 0 means this is the last sector and the SECTOR byte
        ; is the index of its last used byte.
        ; Take them BEFORE sending: send_block writes the count over BUF+1.
        lda BUF+0
        bne @full
        ldx BUF+1               ; index of the last used byte -> one less to send
        dex
        stx v_cnt
        jsr send_block
        jmp @stop
@full:
        sta v_trk
        lda BUF+1
        sta v_sec
        lda #254                ; a full sector: offsets 2..255
        sta v_cnt
        jsr send_block
        bcc @chain              ; carry set: the host took the bus back
        bcs done
@stop:
        ; A zero-length block is the end marker.
        lda #$00
        sta v_cnt
        jsr send_block
done:
        lda VIA2
        and #<~D_LINES
        sta VIA2                ; leave both lines released
        ; RETURN TO THE DOS. Spinning here instead leaves the drive deaf to the
        ; bus -- the very failure this loader was added to stop causing (`ls`
        ; afterwards found nothing until the drive was reset). M-E reaches us
        ; through the command parser, so an rts unwinds back into it.
        rts

; ---------------------------------------------------------------------------
; find_file - walk the directory for fname. Carry clear = found, and
; v_trk/v_sec hold the first data sector.
; ---------------------------------------------------------------------------
find_file:
        lda #DIR_TRK
        sta v_trk
        lda #DIR_SEC
        sta v_sec
@sector:
        jsr read_sector
        bcs @nope
        lda #2                  ; entries start after the two link bytes and
        sta v_ent               ; run 2, 34, 66 ... 226
@entry:
        ldx v_ent
        lda BUF,x               ; file type. Only a CLOSED PRG will do -- what
        and #$87                ; stock LOAD takes: bit 7 closed, bits 0-2 the
        cmp #$82                ; type (2 = PRG), bit 6 (locked) ignored. An
        bne @next               ; empty slot, a splat, a SEQ: not ours. The host
                                ; then falls back to the drive's own lookup.
        jsr name_matches
        bcs @next
        ldx v_ent
        lda BUF+1,x
        sta v_trk
        lda BUF+2,x
        sta v_sec
        clc
        rts
@next:
        lda v_ent
        clc
        adc #32
        sta v_ent
        bcc @entry              ; eight entries fit below $0400, so the carry
                                ; out is "past the last one"
        lda BUF+0               ; follow the directory's own chain
        beq @nope
        sta v_trk
        lda BUF+1
        sta v_sec
        jmp @sector
@nope:
        sec
        rts

; name_matches - compare fname against the 16-byte name at BUF + v_ent + 3.
; Carry clear = match. A short name is padded with $A0, as the directory is.
; CBM wildcards: `*` matches the rest of the name, `?` any one character (but
; not the padding past the end). `load *` and `load pro*` stay on the fast path.
name_matches:
        lda v_ent
        clc
        adc #3
        tax                     ; X walks the directory entry's name
        ldy #0                  ; Y walks ours
@cmp:
        lda #$A0
        cpy fname_len
        bcs @pad
        lda fname,y
        cmp #'*'
        beq @yes                ; the rest matches whatever it is
        cmp #'?'
        bne @pad
        lda BUF,x
        cmp #$A0                ; any one character -- but one must be there
        beq @no
        bne @step
@pad:
        cmp BUF,x
        bne @no
@step:
        inx
        iny
        cpy #16
        bne @cmp
@yes:
        clc
        rts
@no:
        sec
        rts

; ---------------------------------------------------------------------------
; read_sector - job-queue read of v_trk/v_sec into BUF. Carry set on error.
; INTERRUPTS MUST BE ON: the controller runs the job under IRQ, so a `sei`
; here waits for a job that can never start.
; ---------------------------------------------------------------------------
read_sector:
        lda #2
        sta v_try
@again:
        ; Kick the controller's tick. The job loop runs from VIA2 timer 1's IRQ,
        ; every $3A00 cycles (14.8 ms), so a job posted between ticks waits up
        ; to a whole period before the controller even looks at it. Writing 1
        ; to T1C-H reloads the counter as $0100 -- an IRQ in 256 us -- and also
        ; sets the latch's high byte, so the real one is put straight back.
        lda VIA2T1LH
        ldy #$01
        sty VIA2T1CH
        sta VIA2T1LH
        cli
        lda v_trk
        sta JOBTRK
        lda v_sec
        sta JOBSEC
        lda #READJOB
        sta JOBCODE
@wait:
        lda JOBCODE
        bmi @wait               ; still queued/running while bit 7 is set
        cmp #$02                ; 1 = OK; anything higher is an error code
        bcc @out
        ; A failed read gets ONE retry. If it failed on the disk ID, adopt the
        ; ID the header actually carried first -- which is how this code gets
        ; by without an `I0`. The controller compares every header against the
        ; ID it believes is mounted ($12/$13), nothing has set that since the
        ; disk went in, and the header it just rejected left its real ID at
        ; $16/$17. Initialising from the host did the same job for 1.36 s a load;
        ; the cartridge does it this way.
        cmp #ERR_ID
        bne @retry
        lda HDRID
        sta DISKID
        lda HDRID+1
        sta DISKID+1
@retry:
        dec v_try
        bne @again
        sec
@out:
        rts

; ---------------------------------------------------------------------------
; send_block - CLK high, length byte, the sector's data bytes, CLK low.
;
; The length goes out as the first byte of the same loop: it is written over
; BUF+1 -- the link's sector byte, already taken by the caller -- and the loop
; starts there. That is the cartridge's trick (its `STX $0401`), and it retired
; a separate send_byte routine for the one byte in 255 that was not data. A
; zero count sends just that byte: the end-of-file block.
; ---------------------------------------------------------------------------
; Carry set on return = the host has taken the bus back (ATN asserted) and we
; should stop. The check lives BETWEEN bytes on purpose: inside send_byte's
; wait loop it would cost cycles the first pair cannot spare.
send_block:
        sei
        lda VIA2
        and #<~D_LINES
        sta v_base              ; kept for the block framing and @abort
        lda VIA2
        bmi @abort              ; ATN asserted: the host wants the bus back
        ; CLK low then high: the edge the host's _epyx_wait_ready waits for.
        ; It does not need to catch the low, so a brief one is fine; CLK is
        ; then held high while the loop waits for the host.
        ora #D_COUT
        sta VIA2                ; CLK low  = "not ready"
        lda v_base
        sta VIA2                ; CLK high = "ready"
        ldx v_cnt
        stx BUF+1               ; the count, sent first
        inx
        stx v_last              ; data lives at BUF+2 .. BUF+1+cnt
        ldy #0
@next:
        iny                     ; 2
        lda BUF,y               ; 4   BUF is page-aligned: never a page cross
        lsr a                   ; 2
        lsr a                   ; 2
        lsr a                   ; 2
        lsr a                   ; 2
        tax                     ; 2   X = high nibble, pair 1 ready to store
        lda #D_DIN              ; 2   $01: both lines released = "ready", and the
        sta VIA2                ; 4   mask the BIT below tests with
@wait:
        bit VIA2                ; 4   Z = (VIA2 & $01) == 0
        bne @wait               ; 3   spin while the host still holds DATA low
        stx VIA2                ; 4   pair 1
        txa                     ; 2
        asl a                   ; 2
        and #$0F                ; 2
        sta VIA2                ; 4   pair 2   (+10)
        lda BUF,y               ; 4
        and #$0F                ; 2
        sta VIA2                ; 4   pair 3   (+10)
        asl a                   ; 2
        and #$0F                ; 2
        nop                     ; 2
        sta VIA2                ; 4   pair 4   (+10)
        cpy v_last              ; 4
        bne @next               ; 3
        ; End of block, straight to "not ready" in ONE store. The window where
        ; CLK reads high with nothing driving it is what used to give exactly
        ; one bad byte at the first offset of the second sector. Pair 4 still
        ; outlives the host's sample: sixteen cycles pass before this store.
        lda v_base
        ora #D_COUT
        sta VIA2
        clc
        rts
@abort:
        lda v_base
        sta VIA2
        sec
        rts

