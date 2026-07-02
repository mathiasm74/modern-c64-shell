; iec.s - Commodore IEC serial bus, controller side (Phase 6).
;
; The C64 is always the bus controller. To read a file we LISTEN the drive,
; send the open command + filename, UNLISTEN, then TALK it and receive bytes
; with ACPTR. These routines bit-bang CIA #2 port A ($DD00); the lines are
; open-collector and inverted at the port: writing a 1 to an output bit pulls
; the line LOW, writing 0 releases it (the bus pulls it HIGH). Input bits read
; the line level directly (1 = high/released, 0 = low/pulled).
;
;   bit 3 ($08) ATN  out      bit 6 ($40) CLK  in
;   bit 4 ($10) CLK  out      bit 7 ($80) DATA in
;   bit 5 ($20) DATA out
;
; Timing is handshake-driven (we wait on line states), so generous delays are
; safe. We mask IRQs across each transfer so the ~60 Hz keyboard scan can't
; jitter a byte; the scan still runs between bytes.
;
; The protocol is intricate and tightly coupled -- see any C64 KERNAL
; reference (e.g. "How the VIC/64 serial bus works", Jim Butterfield).

.export iec_init
.export _iec_set_fa, _iec_set_sa, _iec_setname
.export _iec_set_fnadr, _iec_set_fnlen, _iec_command_raw
.export _iec_open, _iec_command, _iec_chkin, _iec_getbyte, _iec_close, _iec_clrchn
.export _iec_chkout, _iec_putbyte, _iec_puteoi, _iec_unlisten
.export _iec_status
.export wait_clk_lo, wait_clk_hi        ; used by the Epyx host transmit (fastload_send.s)

DD00   = $DD00
DDR2   = $DD02

B_ATN  = $08
B_CLK  = $10
B_DATA = $20
; input senses tested via BIT: V = bit6 (CLK in), N = bit7 (DATA in)

; --- working storage (standard KERNAL zero-page locations) ---------------
ST     = $90            ; I/O status byte
FNLEN  = $B7            ; filename length
SA     = $B9            ; secondary address (channel)
FA     = $BA            ; device number
FNADR  = $BB            ; $BB/$BC: filename pointer
BSOUR  = $95            ; the byte being sent / received
COUNT  = $A3            ; bit counter (used inside iec_sendbyte)
NAMEIDX = $A4           ; filename index (survives iec_sendbyte)
EOIBUF = $A5            ; EOI flag for the byte being sent
TMOUT  = $A6            ; receive-wait timeout countdown
SECADR = $A9            ; secondary address held across the LISTEN command send
IECRAW = $A7            ; raw-mode flag (1 = skip lowercase-to-uppercase fold
                        ; when sending the name buffer; 0 = fold).  Standard
                        ; KERNAL reserves $A7 as "RIBYTE" general I/O scratch
                        ; -- since we don't run the KERNAL receive path, it's
                        ; free for us to repurpose.

.segment "KCODE"

; -------------------------------------------------------------------------
; iec_init - make ATN/CLK/DATA outputs and release the bus. Called from
; reset.s after the CIA #2 bank bits are set; preserves those (bits 0-2).
; -------------------------------------------------------------------------
iec_init:
        lda #$00
        sta IECRAW              ; default: fold lowercase->uppercase in names
        lda DDR2
        ora #(B_ATN | B_CLK | B_DATA)   ; bits 3,4,5 are outputs
        sta DDR2
        lda DD00
        and #<~(B_ATN | B_CLK | B_DATA) ; release all three lines
        sta DD00
        rts

; --- single serial-line operations (clobber A only) ----------------------
atn_lo:
        lda DD00
        ora #B_ATN
        sta DD00
        rts
atn_hi:
        lda DD00
        and #<~B_ATN
        sta DD00
        rts
clk_lo:
        lda DD00
        ora #B_CLK
        sta DD00
        rts
clk_hi:
        lda DD00
        and #<~B_CLK
        sta DD00
        rts
data_lo:
        lda DD00
        ora #B_DATA
        sta DD00
        rts
data_hi:
        lda DD00
        and #<~B_DATA
        sta DD00
        rts

; ~40us settle, used between bit edges. Clobbers Y.
iec_settle:
        ldy #$08
@l:     dey
        bne @l
        rts

; Wait for a device to pull DATA low (its response to ATN). Returns carry
; clear if one did, carry set on timeout (~tens of ms) = no device present.
; Clobbers A, X, Y.
iec_wait_dev:
        ldx #$20
        ldy #$00
@l:
        bit DD00
        bpl @present            ; DATA low (N clear) -> a device answered
        dey
        bne @l
        dex
        bne @l
        sec                     ; timed out: nobody home
        rts
@present:
        clc
        rts

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

; wait_clk_lo_short - like wait_clk_lo but with a SHORT (~75ms) timeout, used
; only for the post-EOI final byte (iec_getbyte): once we ack EOI, a 1541 clocks
; that last byte out within ~1ms, but a Meatloaf/SD2IEC sends nothing and goes
; idle -- the full ~1.4s wait_clk_lo then stalled the prompt at the end of every
; cat/less/load/dir. ~75ms is ample for any 1541-family drive (the byte is
; already in its buffer, no sector read) yet imperceptible on an idle bus.
; Carry clear = CLK went low (a real final byte follows), set = timed out (idle).
wait_clk_lo_short:
        ldx #$20                ; ~32 * 256 * 9cyc ~= ~75ms
@x:     ldy #$00
@y:     bit DD00
        bvc @ok                 ; CLK low
        dey
        bne @y
        dex
        bne @x
        sec
        rts
@ok:    clc
        rts

; Wait for DATA in to go low (~0.7s timeout). Carry clear once it does, carry
; set on timeout. iec_sendbyte's first handshake uses this so an absent or
; unaddressed device (which never pulls DATA low) can't wedge the send; once a
; listener answers, the rest of the byte is sent with unbounded waits so a
; busy-but-present drive isn't falsely abandoned. Clobbers A, X, Y.
wait_data_lo:
        ldx #$00
@x:     ldy #$00
@y:     bit DD00
        bpl @ok                 ; DATA low (N clear)
        dey
        bne @y
        dex
        bne @x
        sec
        rts
@ok:    clc
        rts

; iec_sendbyte's byte-ack wait. For DATA bytes (ATN released) it spins
; unbounded on purpose: a present-but-busy drive (flushing a write to disk)
; may legitimately stall an ack well past any reasonable timeout. UNDER ATN
; it is bounded (~0.7s): once a listener releases DATA ("ready") it is
; actively receiving and acks within about a millisecond, and an unbounded
; wait here wedges the machine when the bus empties mid-byte -- seen on
; hardware when a mid-transfer cable yank's contact bounce faked fload's
; presence probe past its gate: the bits clocked into the floating bus (DATA
; reads high, so the ready-wait sailed through), then the ack never came and
; the C64 spun until the cable returned, whereupon the drive's ATN response
; supplied the missing "ack" and the probe reported a phantom success.
; NOTE the asymmetry: the READY wait (DATA release, @wready) must stay
; unbounded even under ATN -- a drive that just took an OPEN is busy seeking
; the directory for up to several seconds before it services the TALK bytes
; (the stock KERNAL waits forever there too), and a floating bus passes that
; wait instantly anyway, so it is not a yank wedge point.
hs_ack:
        lda DD00
        and #B_ATN              ; are we asserting ATN? -> bounded wait
        bne wait_data_lo
@spin:  bit DD00
        bmi @spin               ; wait for DATA low = the listener's byte ack
        clc
        rts

; -------------------------------------------------------------------------
; C-callable setters (one argument, in A / A:X per cc65 fastcall).
; -------------------------------------------------------------------------
_iec_set_fa:                    ; void iec_set_fa(unsigned char dev)
        sta FA
        rts

_iec_set_sa:                    ; void iec_set_sa(unsigned char sa)
        sta SA
        rts

_iec_setname:                   ; void iec_setname(const char *name)  A=lo X=hi
        sta FNADR
        stx FNADR+1
        ldy #$00                ; measure length up to the NUL (cap 40: leaves
@scan:  lda (FNADR),y           ; room for `R0:NEWNAME=OLDNAME` -- two 16-char
        beq @done               ; CBM names plus the rename prefix/separator)
        iny
        cpy #40
        bne @scan
@done:  sty FNLEN
        rts

; iec_setname's NUL-scan can't carry binary data containing zero bytes (M-W
; payloads, addresses, etc.), so we expose the FNADR / FNLEN setters directly
; for the fast loader's upload phase. Pair with iec_command_raw below.
_iec_set_fnadr:                 ; void iec_set_fnadr(const void *p)  A=lo X=hi
        sta FNADR
        stx FNADR+1
        rts
_iec_set_fnlen:                 ; void iec_set_fnlen(unsigned char len)  A=len
        sta FNLEN
        rts

; Same as iec_command but flags the name-send loop to ship bytes verbatim,
; without folding ASCII lowercase to PETSCII uppercase. M-W / M-E / M-R bodies
; mix the literal "M-W" / "M-E" / "M-R" prefix with binary address bytes; the
; fold would corrupt any payload byte that happens to land in $61..$7A.
_iec_command_raw:
        lda #$01
        sta IECRAW
        jsr _iec_command
        lda #$00
        sta IECRAW
        rts

_iec_status:                    ; unsigned char iec_status(void)
        lda ST
        ldx #$00
        rts

; -------------------------------------------------------------------------
; iec_sendbyte - send BSOUR to the bus. Carry set on entry = send with EOI.
; ATN state is whatever the caller set. Precondition: we hold CLK low and
; have released DATA; a listener holds DATA low. Clobbers A, X, Y.
; -------------------------------------------------------------------------
iec_sendbyte:
        ror EOIBUF              ; stash carry (EOI) in bit 7
        lda ST
        and #$80                ; device already gone? skip (don't re-wait)
        bne @abort
        jsr data_hi             ; talker releases DATA
        jsr clk_lo              ; we hold the clock low
        jsr wait_data_lo        ; bounded: is a listener there to pull DATA low?
        bcs @nodev              ; nobody answered -> device not present
        ; A listener answered. The remaining waits are UNBOUNDED on purpose: a
        ; present-but-busy drive (e.g. seeking track 18 to start a directory)
        ; can stall the byte-ack well past a timeout, and we must not abandon a
        ; device we've already confirmed is there.
        jsr clk_hi              ; release CLK = "ready to send"
@wready:
        bit DD00
        bpl @wready             ; wait for listener to release DATA = "ready"

        bit EOIBUF
        bpl @noeoi              ; EOI flag clear -> no EOI handshake
@eoiack:
        bit DD00
        bmi @eoiack             ; wait for DATA low (listener's EOI acknowledge)
@eoirel:
        bit DD00
        bpl @eoirel             ; wait for DATA high (listener releases)
@noeoi:
        jsr clk_lo              ; pull CLK low to start clocking bits
        lda #$08
        sta COUNT
@bit:
        jsr iec_settle
        lsr BSOUR               ; LSB -> carry
        bcs @one
        jsr data_lo             ; '0' bit
        jmp @clk
@one:
        jsr data_hi             ; '1' bit
@clk:
        jsr clk_hi              ; rising edge clocks the bit
        jsr iec_settle
        jsr clk_lo
        jsr data_hi             ; release DATA between bits
        dec COUNT
        bne @bit
        jsr hs_ack              ; DATA low = the listener's byte ack
        bcs @nodev              ; (bounded under ATN -- see hs_ack)
        rts
@nodev:
        lda ST                  ; nobody acknowledged: device not present
        ora #$80
        sta ST
@abort:
        rts

; Send a command byte (in A) under ATN -- no EOI, ATN already asserted.
send_cmd:
        sta BSOUR
        clc
        jmp iec_sendbyte

; -------------------------------------------------------------------------
; _iec_open / _iec_command - LISTEN FA, send a secondary, then the name held
; in FNADR/FNLEN (folded to uppercase PETSCII), then UNLISTEN. open uses the
; open secondary ($F0 | channel); command writes the command channel ($6F =
; channel 15), e.g. "S0:NAME" to scratch a file. Both mask IRQs and set ST.
; void iec_open(void); void iec_command(void);
; -------------------------------------------------------------------------
_iec_open:
        lda SA
        and #$0F
        ora #$F0                ; open secondary address
        jmp send_listen
_iec_command:
        lda #$6F                ; command channel (15), write
send_listen:
        sta SECADR
        php
        sei
        lda #$00
        sta ST
        jsr atn_lo
        jsr clk_lo
        jsr data_hi
        jsr iec_settle
        jsr iec_wait_dev        ; anyone on the bus?
        bcs @nodev              ; no device: flag it and bail out
        lda FA
        ora #$20                ; LISTEN command
        jsr send_cmd
        lda SECADR
        jsr send_cmd            ; the secondary
        lda ST                  ; addressed device absent (a send timed out)?
        and #$80
        bne @fail               ; yes: release the bus cleanly, don't toggle ATN
        jsr atn_hi              ; command phase done; the name is data
        ; send FNADR/FNLEN, EOI on the last byte (NAMEIDX survives the send).
        lda #$00
        sta NAMEIDX
@name:
        lda NAMEIDX
        cmp FNLEN
        bcs @unlisten           ; index >= length -> whole name sent
        ldy NAMEIDX
        lda (FNADR),y
        ; In raw mode (IECRAW != 0) the name buffer is binary -- M-W payload
        ; bytes for the drive, addresses, etc. -- so we send it untouched.
        ; In normal mode we fold lowercase to uppercase: disk names/commands
        ; are uppercase PETSCII, our shell types lowercase ASCII.
        ldx IECRAW
        bne @putname
        cmp #$61
        bcc @putname
        cmp #$7B
        bcs @putname
        and #$DF                ; clear bit 5: lowercase -> uppercase
@putname:
        sta BSOUR               ; the byte to send
        inc NAMEIDX
        lda NAMEIDX
        cmp FNLEN               ; carry set iff that was the last byte -> EOI
        jsr iec_sendbyte
        jmp @name
@unlisten:
        lda ST
        and #$80                ; device vanished mid-name?
        bne @fail               ; yes: just release, don't re-assert ATN
        jsr atn_lo
        jsr clk_lo
        jsr iec_settle
        lda #$3F
        jsr send_cmd
        jsr atn_hi
        jsr clk_hi              ; release the bus
        plp
        rts
@nodev:                         ; nobody answered ATN at all: just release
        lda #$80
        sta ST
        jsr atn_hi
        jsr clk_hi
        jsr data_hi
        plp
        rts
@fail:                          ; the addressed device is absent but others may
        ; be on the bus and saw our partial command -- broadcast UNLISTEN and
        ; UNTALK (which a present device acknowledges) so it returns to idle.
        lda #$00
        sta ST                  ; clear the flag so the sends run
        jsr atn_lo
        jsr clk_lo
        jsr data_hi
        jsr iec_settle
        lda #$3F                ; UNLISTEN
        jsr send_cmd
        lda #$5F                ; UNTALK
        jsr send_cmd
        jsr atn_hi
        jsr clk_hi
        jsr data_hi
        lda #$80                ; restore the device-not-present status
        sta ST
        plp
        rts

; -------------------------------------------------------------------------
; _iec_chkin - TALK FA, send talk-secondary, turn the bus around so the
; drive becomes talker and we become listener. void iec_chkin(void).
; -------------------------------------------------------------------------
_iec_chkin:
        php
        sei
        jsr atn_lo
        jsr clk_lo
        jsr data_hi
        jsr iec_settle
        jsr iec_wait_dev
        bcs @nodev              ; no device: flag and bail
        lda FA
        ora #$40                ; TALK command
        jsr send_cmd
        lda SA
        and #$0F
        ora #$60                ; talk secondary
        sta BSOUR
        clc
        jsr iec_sendbyte
        ; turnaround: we become listener
        jsr data_lo             ; hold DATA low (listener present)
        jsr atn_hi              ; release ATN
        jsr clk_hi              ; release CLK (drive takes it)
        jsr wait_clk_lo         ; wait for the drive to pull CLK low (timeout)
        bcs @stuck
        plp
        rts
@stuck:
        lda ST                  ; turnaround failed: read timeout
        ora #$02
        sta ST
        plp
        rts
@nodev:
        lda #$80
        sta ST
        jsr atn_hi
        jsr clk_hi
        plp
        rts

; -------------------------------------------------------------------------
; _iec_getbyte - receive one byte from the talker (ACPTR). Returns it in A
; (X=0). Sets ST bit $40 on EOI (the last byte). unsigned char iec_getbyte().
; -------------------------------------------------------------------------
_iec_getbyte:
        php
        sei
        lda ST                  ; once a read has timed out, don't retry (and
        and #$02                ; pay the timeout again) for every later byte
        bne @giveup
        ; 1. wait for the talker to release CLK = "ready to send". Times out so
        ;    a dead or disk-less drive can't wedge the shell.
        jsr wait_clk_hi
        bcs @timeout
        ; 2. release DATA = "listener ready for data"
        jsr data_hi
        ; 3. wait for CLK to go low (talker starts clocking bits). If it stays
        ;    high past the short window, this is EOI (the last byte).
        ; 3. wait for CLK to go low (talker clocking the byte's bits). If CLK
        ;    instead stays high past the window, the talker is signalling
        ;    end-of-data, and the two drive families do it differently:
        ;      - a 1541 holds CLK high until we acknowledge EOI, then clocks out
        ;        one final byte (the EOI byte); we read it and return it with EOI.
        ;      - Meatloaf (and SD2IEC-likes) stream every byte at full speed with
        ;        no EOI hold and then simply go idle. Here the window elapses on
        ;        the idle bus and NO final byte follows -- a CLEAN end of stream,
        ;        not an error, so we return EOI WITHOUT the read-timeout bit.
        ;    Normal bytes pull CLK low within microseconds, far inside the window,
        ;    so this only ever triggers at the actual end of a transfer.
        ldy #$00                ; inner 256-iteration counter
        lda #$10                ; outer ticks: ~16 * 2.86ms ~= 46ms end-of-data wait
        sta COUNT
@eoi:
        bit DD00
        bvc @gotclk             ; CLK low -> a real byte is coming
        dey
        bne @eoi
        dec COUNT
        bne @eoi
        lda ST                  ; window elapsed -> end of data: flag EOI, then
        ora #$40                ; acknowledge and see whether a final byte follows
        sta ST
        jsr data_lo             ; pulse DATA low ...
        jsr iec_settle
        jsr data_hi             ; ... then release; a 1541 now sends its last byte
        jsr wait_clk_lo_short   ; a 1541 clocks out its final EOI byte within ~1ms;
                                ; a Meatloaf sends none, so use a short timeout so
                                ; the idle bus doesn't stall the prompt ~1.4s
        bcc @gotclk             ; CLK low -> read that byte (returned with EOI set)
        ; timed out -> the bus is idle (Meatloaf-style end of stream). ST already
        ; carries EOI (no $02), so the caller stops without a "read error". Return
        ; no fresh byte: chrout($00) is a no-op and dir_line/load see EOI and stop.
        lda #$00
        ldx #$00
        plp
        rts
@gotclk:
        lda #$08
        sta COUNT
@bit:
        jsr wait_clk_hi         ; bit valid on the rising edge; returns N = DATA,
                                ; sampled by the very `bit DD00` that saw CLK go
                                ; high -- no re-read, so a VIC-II badline can't
                                ; slip into an edge-to-sample gap and shift the
                                ; bit (the garbling fast `ls`/`dir` used to hit).
        bcs @timeout
        bpl @bit0               ; N (DATA) clear -> shift in a 0
        sec                     ; N set -> DATA = 1
        bcs @bitsh              ; (always taken)
@bit0:  clc
@bitsh: ror BSOUR               ; shift DATA into BSOUR, LSB first
        jsr wait_clk_lo         ; talker prepping the next bit
        bcs @timeout
        dec COUNT
        bne @bit
        jsr data_lo             ; acknowledge the byte (listener pulls DATA low)
        lda BSOUR
        ldx #$00
        plp
        rts
@timeout:
        lda ST                  ; read timeout ($02) + EOI ($40) so the caller's
        ora #$42                ; read loop stops cleanly
        sta ST
@giveup:
        lda #$00
        ldx #$00
        plp
        rts

; -------------------------------------------------------------------------
; _iec_close - LISTEN FA, send close-secondary ($E0 | channel), UNLISTEN.
; void iec_close(void).
; -------------------------------------------------------------------------
_iec_close:
        php
        sei
        jsr atn_lo
        jsr clk_lo
        jsr data_hi
        jsr iec_settle
        lda FA
        ora #$20                ; LISTEN
        jsr send_cmd
        lda SA
        and #$0F
        ora #$E0                ; CLOSE secondary
        jsr send_cmd
        jsr atn_lo
        jsr clk_lo
        jsr iec_settle
        lda #$3F                ; UNLISTEN
        jsr send_cmd
        jsr atn_hi
        jsr clk_hi
        plp
        rts

; -------------------------------------------------------------------------
; _iec_clrchn - UNTALK the bus and release it. void iec_clrchn(void).
; -------------------------------------------------------------------------
_iec_clrchn:
        php
        sei
        jsr atn_lo
        jsr clk_lo
        jsr data_hi
        jsr iec_settle
        lda #$5F                ; UNTALK
        jsr send_cmd
        jsr atn_hi
        jsr clk_hi
        jsr data_hi
        plp
        rts

; -------------------------------------------------------------------------
; _iec_chkout - LISTEN FA and send the data secondary ($60 | channel), then
; release ATN so the drive listens for the bytes we CIOUT next. The file must
; already be open for writing (iec_open with a "NAME,P,W" name).
; void iec_chkout(void).
; -------------------------------------------------------------------------
_iec_chkout:
        php
        sei
        jsr atn_lo
        jsr clk_lo
        jsr data_hi
        jsr iec_settle
        jsr iec_wait_dev
        bcs @nodev
        lda FA
        ora #$20                ; LISTEN
        jsr send_cmd
        lda SA
        and #$0F
        ora #$60                ; data secondary (write)
        jsr send_cmd
        jsr atn_hi              ; drive now listens for data bytes
        plp
        rts
@nodev:
        lda #$80
        sta ST
        jsr atn_hi
        jsr clk_hi
        plp
        rts

; _iec_putbyte - send one data byte (in A) to the listening drive (CIOUT, no
; EOI). void iec_putbyte(unsigned char b).
_iec_putbyte:
        php
        sei
        sta BSOUR
        clc                     ; no EOI: more data follows
        jsr iec_sendbyte
        plp
        rts

; _iec_puteoi - send the FINAL data byte (in A) with EOI, so the drive marks
; the end of the file; CLOSE then finalizes it (without this the file is left
; as a "splat", unclosed). void iec_puteoi(unsigned char b).
_iec_puteoi:
        php
        sei
        sta BSOUR
        sec                     ; EOI: this is the last byte
        jsr iec_sendbyte
        plp
        rts

; _iec_unlisten - send UNLISTEN, ending the data write. void iec_unlisten(void).
_iec_unlisten:
        php
        sei
        jsr atn_lo
        jsr clk_lo
        jsr iec_settle
        lda #$3F
        jsr send_cmd
        jsr atn_hi
        jsr clk_hi
        plp
        rts
