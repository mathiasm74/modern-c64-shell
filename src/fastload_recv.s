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

.export _epyx_recv_byte, _epyx_wait_ready, _epyx_recv_prg

.import wait_clk_lo, wait_clk_hi

CHROUT  = $FFD2

CIA2_PRA = $DD00
B_DATA   = $20          ; DATA output (1 = pull DATA low)
VIC_RASTER = $D012      ; VIC-II raster line (low 8 bits) -- for badline avoidance
YSCROLL  = $03          ; our $D011 = $1B, so badlines fall on (RASTER & 7) == 3

A3LOC = $02A8           ; constant-bit smear the fold accumulates (cancel per byte)
A3TMP = $02A9           ; scratch while computing A3LOC (unused page-3 KERNAL RAM)
RETRY = $02AA           ; wait_ready retry countdown (memory: wait_clk_hi eats X)
RES = $FB               ; assembled byte scratch (reset's boot pointer; free now)

; Segment: THREE homes for one source. The KERNAL half normally; the DISK BANK
; links it into its own image at $A000 (docs/ROM-EXPANSION.md), where CODE2 does
; not exist; and KLOAD_BUILD puts it in the patch that is poked into the served
; STOCK KERNAL's tape space (src/kload.s, docs/TAPE-SPACE.md), where it runs with
; our ROM gone entirely. Everything it touches -- $FB-$FE, $02A8-$02B0, $FFD2 --
; is as free under the stock ROMs as under ours, which is what makes the third
; home a segment change rather than a port.
.ifdef KLOAD_BUILD
.define CSEG "KLOAD"
.elseif .defined(BANK_BUILD)
.define CSEG "CODE"
.else
.define CSEG "CODE2"
.endif

.segment CSEG

; ----------------------------------------------------------------------------
; _epyx_wait_ready - wait for the drive's block "ready" signal: CLK goes low
; ("not ready", end of the previous block / opening the file) then high
; ("ready" with the next block). Returns A=0 on success, A=1 on timeout.
; ----------------------------------------------------------------------------
.proc _epyx_wait_ready
        ; --- capture the constant-bit smear for _epyx_recv_byte's fold ---------
        ; The fold XORs four $DD00 samples together with shifts. Bits 6/7 carry
        ; the data; bits 0-4 (VIC bank, ATN/CLK-out, etc.) are FIXED for the whole
        ; transfer and bit5 (DATA-out) reads 0 while sampling -- so they contribute
        ; a constant pattern A3 = x ^ (x>>2) ^ (x>>4) with x = $DD00 & $1F, which
        ; recv_byte cancels with one EOR. Recompute it once per block (cheap, and
        ; both the PRG and the dir paths reach a byte only through here).
        lda CIA2_PRA
        and #$1F
        sta A3TMP                       ; x
        lsr a
        lsr a                           ; x>>2
        eor A3TMP
        sta A3LOC                       ; x ^ (x>>2)
        lda A3TMP
        lsr a
        lsr a
        lsr a
        lsr a                           ; x>>4
        eor A3LOC
        sta A3LOC                       ; A3 = x ^ (x>>2) ^ (x>>4)
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
        lda #$04                        ; ~4 * 1.4s: rides out a slow (network)
                                        ; file lookup without stalling ~14s on a
                                        ; drive wedged holding CLK low. A yanked
                                        ; cable never gets here (pull-ups fake a
                                        ; clean EOF; fload_program's presence
                                        ; probe catches that case instead).
        sta RETRY                       ; count in memory, NOT X: wait_clk_hi
@hi:                                    ; exits its timeout with X=0, so an X
        jsr wait_clk_hi                 ; ladder wrapped to $FF on every retry
        bcc @ok                         ; and never gave up -- the give-up had
        dec RETRY                       ; never actually fired until this fix
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
        ; Badlines only fire while the raster is in the visible window $30..$F7
        ; (RASTER & 7 == YSCROLL there). Outside it -- top/bottom border -- every
        ; raster line is safe, so gate the offset check by the window first. The
        ; last raster a byte must avoid is $F3 (the highest badline line); from
        ; $F4 up the worst-case sample window can't reach a badline, so accept.
        ; This is the Epyx cart's trick (it uses a 256-byte raster table; the two
        ; compares bracket the same band for our single contiguous window) and it
        ; drops the needless border waits the old `and #7` check imposed.
@badline:
        lda VIC_RASTER
        cmp #$30
        bcc @clear                      ; below the window -> no badlines, safe
        cmp #$F4
        bcs @clear                      ; past the last dangerous line -> safe
        and #$07
        beq @clear                      ; offset 0 inside window -> clear
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
        ;
        ; The de-interleave is folded INTO this loop (the Epyx cart's trick): the
        ; four reads stay at the same cycle offsets, but the inter-sample filler
        ; does `lsr a; lsr a; nop` (6 cyc, was `sta Sx; nop`) so the byte XOR-
        ; accumulates as we go, and the reads after the first use `eor` instead of
        ; `lda`. After sample 4 A holds the scrambled fold
        ;   F = (S0>>6) ^ (S1>>4) ^ (S2>>2) ^ S3
        ; which carries the data bits (inverted, permuted) plus the constant smear
        ; A3 captured in _epyx_wait_ready. One `eor A3LOC` clears the constant and
        ; one 256-byte table descrambles -- ~13 cyc in the drive-blocking gap vs
        ; the ~68 the separate de-interleave used to cost. Timing is unchanged:
        ; every $DD00 read is at the same offset as before.
        nop
        nop
        nop
        nop
        nop
        lda CIA2_PRA                    ; sample 1 (+14): ~d7/~d5
        lsr a
        lsr a
        nop
        eor CIA2_PRA                    ; sample 2 (+24): ~d6/~d4
        lsr a
        lsr a
        nop
        eor CIA2_PRA                    ; sample 3 (+34): ~d3/~d1
        lsr a
        lsr a
        nop
        eor CIA2_PRA                    ; sample 4 (+44): ~d2/~d0
        tax                             ; stash the fold (got-it clobbers A)

        ; "got it": pull DATA low (drive's transmitEpyxByte waits for this).
        lda CIA2_PRA
        ora #B_DATA
        sta CIA2_PRA
        plp

        ; --- descramble (not time-critical: DATA is low, the drive is waiting).
        ;     Cancel the constant smear, then one table load turns the folded
        ;     value into the byte (the table bakes in the wire inversion + the
        ;     bit permutation; see _epyx_gen_descramble).  ---
        txa
        eor A3LOC
.ifdef KLOAD_BUILD
        ; TWO 16-BYTE TABLES instead of one 256-byte one. The permutation is
        ; nibble-separable -- the folded value's low nibble becomes the result's
        ; HIGH nibble and vice versa, and both go through the SAME nibble
        ; permutation (swap bits 0 and 3), verified identical to the big table
        ; for all 256 inputs. That matters because the stock KERNAL's tape space
        ; is 684 bytes total and the big table alone would eat 256 of them.
        ;
        ; It costs ~26 cycles a byte over the single lookup. Affordable: the
        ; drive waits on our DATA-high before every byte, so a slower host is a
        ; slower transfer, never a corrupt one -- and even 30% off is still an
        ; order of magnitude up on the stock loader this replaces.
        tax                             ; keep the folded byte (X is clobbered
                                        ; on return anyway -- see the ldx below)
        and #$0F
        tay
        lda ds_hi,y
        sta A3TMP
        txa
        lsr a
        lsr a
        lsr a
        lsr a
        tay
        lda ds_lo,y
        ora A3TMP
.else
        tay
        lda descramble,y
.endif
        ldx #$00
        rts
.endproc

; Epyx descramble table (see _epyx_recv_byte). The fold leaves the data bits
; inverted and permuted: folded value v has v0=~d7 v1=~d5 v2=~d6 v3=~d4 v4=~d3
; v5=~d1 v6=~d2 v7=~d0 (after A3 cancels the constant). descramble[v] inverts and
; reorders them back into the byte d7..d0: invert v (all bits are inverted on the
; wire), swap bits 1<->2 and 5<->6, then bit-reverse.
;
; It is a fixed permutation, so it is built HERE, at assembly time, and lives in
; ROM. It used to be generated into RAM at run time to save ~226 bytes of ROM --
; a good trade when this code was resident in the 16KB image, and a bad one now
; that it lives in the disk bank: the bank has ROM to spare but its RAM is carved
; out of the program load area, so 256 bytes of table cost 256 bytes off the
; largest program the machine can load. Assembling it also drops the generator
; and the per-entry call to it in crt0_disk.s (a bank re-inits on EVERY entry, so
; that was rebuilding the same 256 bytes before every disk command).
.ifdef KLOAD_BUILD
.define RSEG "KLDATA"
.elseif .defined(BANK_BUILD)
.define RSEG "RODATA"
.else
.define RSEG "RODATA2"
.endif

.ifdef KLOAD_BUILD
.segment RSEG
; ds_hi[n] = P(n EOR $0F) << 4 and ds_lo[n] = P(n EOR $0F), where P swaps bits 0
; and 3 of a nibble. The EOR carries the protocol's bit inversion, which commutes
; with a permutation, so it folds into the tables for free.
ds_hi:  .byte $F0, $70, $D0, $50, $B0, $30, $90, $10
        .byte $E0, $60, $C0, $40, $A0, $20, $80, $00
ds_lo:  .byte $0F, $07, $0D, $05, $0B, $03, $09, $01
        .byte $0E, $06, $0C, $04, $0A, $02, $08, $00
.else
.export descramble

.segment RSEG
descramble:
.repeat 256, v
        .byte ((((~v) & $01) << 7) | (((~v) & $02) << 4) | (((~v) & $04) << 4) | (((~v) & $08) << 1) | (((~v) & $10) >> 1) | (((~v) & $20) >> 4) | (((~v) & $40) >> 4) | (((~v) & $80) >> 7))
.endrepeat
.endif

.segment CSEG

; ----------------------------------------------------------------------------
; _epyx_recv_prg - receive a whole Epyx-streamed PRG into its embedded load
; address. Reuses _epyx_recv_byte (the proven timed sampler + badline pacing)
; and _epyx_wait_ready, but does the block framing, the store, the byte count
; and the progress dots here in tight ASM instead of the cc65 inner loop the
; C wrapper used to run. The drive blocks on our DATA-high before EVERY byte
; (Meatloaf's transmitEpyxByte waits for it), so the cc65 per-byte overhead was
; directly stalling the transfer -- this cuts it to a JSR + a store + a counter.
;
; Stores the PRG load address at LADRL/LADRH ($02AF/$02B0) for the C wrapper.
; Emits a '.' every 4th block and a CR at the end (the same progress dots as
; before). Returns the end address (last byte + 1 = VARTAB) in A/X, or $0000 if
; fewer than 3 bytes arrived (missing file / broken stream) OR the stream ended
; on a ready-timeout instead of the drive's zero-length block (TMOFL): a
; conforming drive ALWAYS terminates with the 0-block, so a timeout mid-file
; means the transfer died and the data is truncated -- report failure rather
; than hand a partial program to `run`. C-callable.
; ----------------------------------------------------------------------------
DST   = $FC             ; $FC/$FD dest pointer (zp, for (DST),y); RES=$FB is taken
BLK   = $FE             ; bytes left in the current block
TMOFL = $02AB           ; ready-timeout flag: EOF via timeout, not the 0-block
TOTL  = $02AC           ; total bytes received (16-bit): <3 check + progress
TOTH  = $02AD
DOTS  = $02AE           ; progress dots printed so far (one per 1024 bytes)
LADRL = $02AF           ; PRG load address, read back by the C wrapper
LADRH = $02B0
BIGFL = $03A4           ; set when the stream ran into the bank's own RAM
; The destination ceiling, tested on each page crossing. In the bank it is the
; bank's own RAM window -- the loader would otherwise overwrite the C stack it is
; running on. In the stock-KERNAL patch there is no bank to protect, so the only
; thing to stay out of is the I/O window at $D000.
.ifdef KLOAD_BUILD
BANKPG = $D0
.else
BANKPG = $9D            ; first page of the bank RAM window (cfg/disk_bank.cfg).
                        ; The banks share one window, so this is the ceiling for
                        ; ANY loaded program.
.endif

.proc _epyx_recv_prg
        lda #0
        sta BLK
        sta DOTS
        sta TOTL
        sta TOTH
        sta TMOFL
        sta BIGFL
        ; --- load address: the first two data bytes set the destination ------
        jsr next_byte
        bcs @fail
        sta DST
        sta LADRL
        jsr next_byte
        bcs @fail
        sta DST+1
        sta LADRH
.ifdef KLOAD_BUILD
        ; SA=0 means "load at the address the CALLER passed in X/Y", which LOAD
        ; stashed at $C3/$C4 before jumping through the vector. The Epyx stream
        ; always carries the file's own address, so honouring that form means
        ; overriding the destination here -- the real Epyx cartridge declines to,
        ; which is why it is slow in `,8` mode and we are not. LADRL/LADRH keep
        ; the file's address; only where the bytes go changes.
        lda $B9                         ; SA
        bne :+
        lda $C3                         ; MEMUSS lo
        sta DST
        lda $C4
        sta DST+1
:
.endif
        lda #2
        sta TOTL                        ; the two address bytes are counted
        ; --- stream the rest into (DST), crossing block boundaries -----------
@loop:
        jsr next_byte
        bcs @eof
        ldy #$00
        sta (DST),y
        inc DST
        bne @count
        inc DST+1
        ; Crossed into a new page: is it the bank's own RAM? `load` (C, in the
        ; bank) checks this per byte, but this loop is the fast path, so the
        ; test rides the page crossing instead -- free on 255 of every 256
        ; bytes. Without it a large program overwrites the DATA/BSS/C stack of
        ; the very bank running this code, mid-transfer.
        lda DST+1
        cmp #BANKPG
        bcs @toobig
@count: inc TOTL
        bne @loop
        inc TOTH
        jmp @loop
@toobig:
        lda #1
        sta BIGFL               ; the caller reports it; this is just failure
        jmp @fail
@eof:
        lda TMOFL
        bne @fail                       ; timeout EOF = truncated -> failure
        lda TOTH
        bne @ok
        lda TOTL
        cmp #3                          ; fewer than 3 bytes -> failure
        bcc @fail
@ok:
.ifndef KLOAD_BUILD
        lda #$0D
        jsr CHROUT                      ; CR: fresh line after the dots
.endif
        lda DST                         ; return end address (VARTAB)
        ldx DST+1
        rts
@fail:
        lda #0
        tax
        rts
.endproc

; next_byte - return the next PRG data byte in A (carry clear), crossing block
; boundaries. Carry set = end of stream: the drive's zero-length block (normal
; EOF) or a ready timeout (broken stream -- flagged in TMOFL so the caller can
; tell a truncated transfer from a clean one). Emits a progress dot at every
; 4th block boundary (in the inter-block gap, where the drive is busy fetching
; the next block anyway). Clobbers A/X/Y.
.proc next_byte
        lda BLK
        bne @have
.ifdef KLOAD_BUILD
        ; No progress dots in the stock-KERNAL patch. Two reasons, either enough:
        ; this loader serves a RUNNING PROGRAM's LOAD, and scribbling dots across
        ; whatever it has on screen is not ours to do (the stock loader honours
        ; MSGFLG $9D for exactly this reason); and the space is needed -- the
        ; tape region is 684 bytes and the descramble table alone is 256.
.else
        ; --- block boundary: one progress dot per 1024 bytes -----------------
        ; want = bytes>>10 = TOTH>>2 = kilobytes so far; catch DOTS up to it.
        ; (Emitted here, in the inter-block gap where the drive is fetching, so
        ; the CHROUT doesn't stall the per-byte transfer.)
@dotchk:
        lda TOTH
        lsr a
        lsr a
        cmp DOTS
        bcc @nodot                      ; want < printed (defensive) -> done
        beq @nodot                      ; caught up
        lda #$2E                        ; '.'
        jsr CHROUT
        inc DOTS
        jmp @dotchk
@nodot:
.endif
        jsr _epyx_wait_ready            ; A=0 ready, A=1 timeout
        bne @tmo
        jsr _epyx_recv_byte             ; block length
        sta BLK
        cmp #$00                        ; re-test: recv_byte's `ldx #0` left Z=1,
        beq @eof                        ; so test the byte itself. 0 length -> EOF
@have:
        dec BLK
        jsr _epyx_recv_byte             ; the data byte
        clc
        rts
@tmo:
        sta TMOFL                       ; A=1 here: mark EOF-by-timeout
@eof:
        sec
        rts
.endproc
