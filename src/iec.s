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
.export _iec_open, _iec_command, _iec_chkin, _iec_getbyte, _iec_close, _iec_clrchn
.export _iec_chkout, _iec_putbyte, _iec_unlisten
.export _iec_status

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

.segment "KCODE"

; -------------------------------------------------------------------------
; iec_init - make ATN/CLK/DATA outputs and release the bus. Called from
; reset.s after the CIA #2 bank bits are set; preserves those (bits 0-2).
; -------------------------------------------------------------------------
iec_init:
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
        ldy #$00                ; measure length up to the NUL (cap 30: room
@scan:  lda (FNADR),y           ; for a 16-char name plus a command prefix)
        beq @done
        iny
        cpy #30
        bne @scan
@done:  sty FNLEN
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
        jsr data_hi             ; talker releases DATA
        jsr clk_lo              ; we hold the clock low
@wlisten:
        bit DD00
        bmi @wlisten            ; wait for a listener to pull DATA low
        jsr clk_hi              ; release CLK = "ready to send"
@wready:
        bit DD00
        bpl @wready             ; wait for listener to release DATA = "ready"

        bit EOIBUF
        bpl @noeoi              ; EOI flag clear -> no EOI handshake
@eoiack:                        ; EOI: listener pulses DATA low, then releases
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
@ack:
        bit DD00
        bmi @ack                ; wait for DATA low = the listener's byte ack
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
        ; disk names/commands are uppercase PETSCII; our shell types lowercase
        ; ASCII, so fold 'a'-'z' ($61-$7A) up to 'A'-'Z' ($41-$5A).
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
        jsr atn_lo
        jsr clk_lo
        jsr iec_settle
        lda #$3F
        jsr send_cmd
        jsr atn_hi
        jsr clk_hi              ; release the bus
        plp
        rts
@nodev:
        lda #$80                ; ST = device not present
        sta ST
        jsr atn_hi
        jsr clk_hi
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
        ldy #$00                ; ~256-iteration EOI window
@eoi:
        bit DD00
        bvc @gotclk             ; CLK low -> bits coming, no EOI
        dey
        bne @eoi
        lda ST                  ; window elapsed -> EOI: flag and acknowledge
        ora #$40
        sta ST
        jsr data_lo             ; pulse DATA low ...
        jsr iec_settle
        jsr data_hi             ; ... then release; the talker now proceeds
        jsr wait_clk_lo         ; wait for CLK low (the last byte's bits)
        bcs @timeout
@gotclk:
        lda #$08
        sta COUNT
@bit:
        jsr wait_clk_hi         ; bit valid on the rising edge
        bcs @timeout
        lda DD00
        asl a                   ; DATA in (bit7) -> carry
        ror BSOUR               ; shift in, LSB first
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
        clc                     ; no EOI: the file ends at CLOSE, not here
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
