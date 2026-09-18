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
.ifndef BANK_BUILD
        php
        sei
.else
        ; No php/sei/plp here: _epyx_recv_prg holds SEI for the whole transfer,
        ; exactly as the cartridge masks CIA1 once per load rather than touching
        ; the I flag per byte. Worth 7 cycles of a ~127-cycle byte. NOTE: any
        ; OTHER caller of this routine must provide its own SEI -- today that is
        ; block_hdr (inside recv_prg's) and dir.c's fast path, which is dormant.
.endif
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
        ; Wait for the drive BEFORE choosing a badline-safe raster, not after.
        ; This wait can be ~150 cycles (the drive is building the next byte's
        ; pairs) which is two or three raster lines -- so a safe offset picked
        ; first is stale by the time we sample, and a badline can steal ~40
        ; cycles in the middle of the byte. That is what was corrupting about
        ; one sector boundary in twenty.
.ifdef BANK_BUILD
        ; The per-byte CLK wait is gone: the drive answers in ~29 cycles now
        ; (src/drive1541.s), so it is always waiting on us, never the reverse.
        ;
        ; The badline gate is a TABLE LOOKUP, which is what the real cartridge
        ; does -- its table lives at $8300 and is indexed by $D012. THE SCREEN
        ; STAYS ON: the cartridge never writes $D011, and blanking buys nothing.
        ; The win is that the lookup costs ~10 cycles against the arithmetic's
        ; ~18, and the entry doubles as the AND mask that releases DATA, so the
        ; release is `and CIA2_PRA`, not a separate `and #imm`.
@badline:
        ldy VIC_RASTER                  ; 4   through Y, NOT X: the caller's
        lda badtab,y                    ; 4   block counter lives in X now
        beq @badline                    ; 2   wait it out; the raster free-runs
        and CIA2_PRA                    ; 4
        sta CIA2_PRA                    ; 4   T = 0 (DATA high)
.else
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
        lda CIA2_PRA
        and #<~B_DATA
        sta CIA2_PRA                    ; T = 0 (DATA high)
.endif

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
        ; --- sample the four pairs -----------------------------------------
        ; TWO timings, because the two kinds of drive answer the DATA release
        ; very differently.
        ;
        ; A Meatloaf answers in ~0 cycles, so its pairs are effectively exact
        ; and ten cycles apart: sample at +14/24/34/44, as it always has.
        ;
        ; A real 1541 cannot. It finds the release with a 9-cycle poll loop and
        ; needs 8 more cycles to store the first pair, so pair 1 lands anywhere
        ; in +8..+17 -- a 10-cycle smear. Against 10-cycle spacing that leaves
        ; ONE cycle of margin, and it showed: 6 loads in 8, the others with a
        ; byte or two flipped where a sample caught the neighbouring pair.
        ; Spacing both sides THIRTEEN cycles apart turns that 1 into 3: pair k
        ; occupies [8+13(k-1), 17+13(k-1)] and the sample sits at 20+13(k-1),
        ; three clear of the pair's end and three before the next begins.
.ifdef BANK_BUILD
        ; Park the ASSERTED line value in Y while we are burning padding
        ; anyway. The re-assert after the samples is then a single `sty`
        ; rather than a read-modify-write -- which is what the real cartridge
        ; does (`ORA #$20 / TAY` in its stage 2, `STY $DD00` in its stage 4).
        ; Ten cycles either way, so every sample offset is unchanged.
        ora #B_DATA                     ; 2   A still holds the RELEASED value
        tay                             ; 2   Y = asserted
        nop                             ; 2
        nop                             ; 2
        nop                             ; 2   -> the same ten cycles
                                        ;     the five nops below were
.else
        nop
        nop
        nop
        nop
        nop
.endif
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
.ifdef BANK_BUILD
        ; One store, and the fold stays in A. The old sequence stashed it in X
        ; only because the read-modify-write re-assert clobbered A; with the
        ; asserted value already in Y there is nothing to stash. 10 cycles.
        sty CIA2_PRA                    ; "got it": pull DATA low
.else
        tax                             ; stash the fold (got-it clobbers A)

        ; "got it": pull DATA low (drive's transmitEpyxByte waits for this).
        lda CIA2_PRA
        ora #B_DATA
        sta CIA2_PRA
        plp
.endif

        ; --- descramble (not time-critical: DATA is low, the drive is waiting).
        ;     Cancel the constant smear, then one table load turns the folded
        ;     value into the byte (the table bakes in the wire inversion + the
        ;     bit permutation; see _epyx_gen_descramble).  ---
.ifndef BANK_BUILD
        txa                             ; bank build: the fold never left A
.endif
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
.ifndef BANK_BUILD
        ldx #$00
.else
        ; X IS PRESERVED on this build, and that is now part of the contract:
        ; _epyx_recv_prg keeps the block's byte count there across the call. The
        ; old `ldx #$00` was cc65's char-return convention, and both C callers
        ; (dir.c) assign to an unsigned char, which needs only A. Restoring it
        ; here wiped the counter every byte and the loop ran for ever -- the
        ; failure mode is a hang, not corruption, so it shows up immediately.
.endif
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
RECV_PAD = $03A6        ; 0 = Meatloaf sample timing, nonzero = real-1541 timing
                        ; (the pad in _epyx_recv_byte). disk_fload sets it per
                        ; path; the KLOAD build has no drive path and the stock
                        ; KERNAL leaves page 3 alone, so it is 0 there.
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
.ifdef BANK_BUILD
        php
        sei                             ; held for the whole transfer, so
                                        ; _epyx_recv_byte pays nothing per byte
.endif
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
.ifdef BANK_BUILD
        ldx BLK                         ; the inner loop owns the count from here
        beq @newblk                     ; a block of exactly two bytes
.endif
        ; --- stream the rest into (DST), crossing block boundaries -----------
@loop:
        ; Common case inline: next_byte's framing only matters at a block
        ; boundary, and paying its jsr/rts plus the BLK test and a clc through
        ; the CALL every byte cost ~11 cycles of the per-byte budget that is
        ; now the whole remaining gap to the cartridge (PLAN.md section 8).
        ; NOTE the test is `lda BLK / beq`, NOT `dec BLK / bmi`: a block length
        ; runs to 254, so the decremented count is "negative" for most of a
        ; block and bmi would take the slow path on nearly every byte.
.ifdef BANK_BUILD
        jsr _epyx_recv_byte
.else
        jsr next_byte                   ; KLOAD has no room for the fast path:
        bcs @eof                        ; it must fit the 684-byte tape region
.endif
@store:
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
@count:
.ifdef BANK_BUILD
        ; `dex / bne`, the shape the cartridge uses. Five cycles where testing
        ; and decrementing a memory BLK took twelve.
        dex
        bne @loop
@newblk:
        jsr block_hdr                   ; C set = EOF or timeout
        bcs @eof
        ldx BLK
        jmp @loop
.else
        inc TOTL                        ; KLOAD keeps the counter: deriving it
        bne @loop                       ; costs 3 bytes it does not have in the
        inc TOTH                        ; 684-byte tape region
        jmp @loop
.endif
@toobig:
        lda #1
        sta BIGFL               ; the caller reports it; this is just failure
        jmp @fail
@eof:
.ifdef BANK_BUILD
        lda DST                         ; total = DST - LADR, computed once
        sec
        sbc LADRL
        sta TOTL
        lda DST+1
        sbc LADRH
        sta TOTH
.endif
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
.ifdef BANK_BUILD
        plp
.endif
        rts
@fail:
        lda #0
        tax
.ifdef BANK_BUILD
        plp
.endif
        rts
.endproc

; next_byte - return the next PRG data byte in A (carry clear), crossing block
; boundaries. Carry set = end of stream: the drive's zero-length block (normal
; EOF) or a ready timeout (broken stream -- flagged in TMOFL so the caller can
; tell a truncated transfer from a clean one). Emits a progress dot at every
; 4th block boundary (in the inter-block gap, where the drive is busy fetching
; the next block anyway). Clobbers A/X/Y.
.ifdef BANK_BUILD
.proc next_byte
        lda BLK
        bne @have
        jsr block_hdr                   ; boundary: sets BLK, C set on EOF
        bcs @out
@have:
        dec BLK
        jsr _epyx_recv_byte             ; the data byte
        clc
@out:
        rts
.endproc

; ---------------------------------------------------------------------------
; block_hdr - the block BOUNDARY half of next_byte: catch the dots up, wait for
; the drive's "ready", take the length byte. Carry clear = BLK holds a nonzero
; count; carry set = EOF (zero length) or a timeout (TMOFL set).
;
; Split out so _epyx_recv_prg's inner loop can own the count in X and reach this
; only at a boundary, instead of testing a memory BLK on every byte. KLOAD keeps
; the monolithic version below: the split costs a jsr/rts pair and it has
; exactly zero bytes to spare in the 684-byte tape region (the build says so).
; ---------------------------------------------------------------------------
.proc block_hdr
@dotchk:
        lda DST+1                       ; TOTH equivalent, derived per block
        sec
        sbc LADRH
        sta TOTH
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
        jsr _epyx_wait_ready            ; A=0 ready, A=1 timeout
        bne @tmo
        jsr _epyx_recv_byte             ; block length
        sta BLK
        cmp #$00                        ; 0 length -> EOF
        beq @eof
        clc
        rts
@tmo:
        sta TMOFL                       ; A=1 here: mark EOF-by-timeout
@eof:
        sec
        rts
.endproc
.else
.proc next_byte
        lda BLK
        bne @have
.ifndef KLOAD_BUILD
@dotchk:
        lda DST+1                       ; TOTH equivalent, derived per block
        sec
        sbc LADRH
        sta TOTH
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
        cmp #$00
        beq @eof                        ; 0 length -> EOF
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
.endif

.ifdef BANK_BUILD
; ---------------------------------------------------------------------------
; badtab - one entry per raster line: $00 = do not START a byte here, anything
; else is the AND mask that releases DATA. The real cartridge's equivalent is
; its $8300 table, and the shared trick is that the live entry IS the mask.
;
; A badline is (RASTER & 7) == YSCROLL within $30..$F7. We block offsets 1..3
; where the cartridge blocks two, and that is not over-caution: its byte is ~63
; cycles, about one raster line, so it only needs the line it starts on. Ours is
; longer and spans two to three lines, so a byte begun at offset 1 would still
; be running when the badline at 3 lands. Offsets 4..7 and 0 give the clear run
; we need. Shorten the byte and this table should be narrowed to match.
.align 256
badtab:
.repeat 256, i
    .if (i >= $30) && (i <= $F7) && ((i & 7) >= 1) && ((i & 7) <= YSCROLL)
        .byte $00
    .else
        .byte <~B_DATA
    .endif
.endrepeat
.endif
