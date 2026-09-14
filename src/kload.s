; ============================================================================
; kload.s -- code patched INTO the served stock KERNAL, in its tape space.
;
; This does NOT run in our environment. It is stored in our KERNAL ROM as data,
; SLOT_POKEd into the stock KERNAL image before the One ROM switches to it, and
; then runs at $F8E2 under the STOCK ROMs with our ROM gone. So it may call the
; stock KERNAL freely ($FFxx and the internal entries below) and may call nothing
; of ours.
;
; WHY HERE. After `run`, a program that keeps loading -- levels, multi-load
; titles -- gets stock-speed loads, because nothing wedges LOAD. A real Epyx
; cartridge stays resident and does, which is why it can be far faster on the
; same drive. Putting the wedge in ROM rather than planting it in RAM is what
; makes it survive: a RAM wedge at $C000 dies to RESTOR, to RUN/STOP+RESTORE and
; to any program that uses that memory.
;
; WHY THE TAPE SPACE. Tape is an explicit non-goal for this shell, and
; docs/TAPE-SPACE.md establishes that $F8E2-$FB8D (684 bytes) is reachable only
; from the tape paths -- no other code reaches it and nothing outside references
; into it. Regenerate that analysis with tools/kernal_map.py.
;
; HOW IT IS HOOKED. Not by patching LOAD's code, but by repointing the ROM's own
; vector table: the ILOAD entry at $FD4C (slot offset $1D4C) is what RESTOR
; copies into $0330. Patching the TABLE means the hook survives any later RESTOR
; the program does -- patching $0330 itself would not.
;
; STAGE 1 (this file today): the dispatch and the fallback only, with a visible
; marker. It ticks the border and hands straight to the stock serial loader, so
; every LOAD still works exactly as before while proving that ~20 bytes reached
; the served ROM and that the repointed vector calls them. The Epyx receiver
; goes in next, in the same space, behind the same dispatch.
; ============================================================================

KLOAD_ORG = $F8E2               ; start of the tape-only run (docs/TAPE-SPACE.md)

; --- stock KERNAL locations this code uses ---------------------------------
ST       = $90                  ; I/O status
FA       = $BA                  ; current device
VERCK    = $93                  ; load/verify flag

STOCK_SERIAL = $F4B8            ; LOAD's serial path, entered past its device
                                ; dispatch: it re-reads FA itself and only needs
                                ; VERCK and ST set, which we do below.
STOCK_ILLEGAL = $F713           ; "illegal device number"
STOCK_NONAME  = $F710           ; "missing file name"
STOCK_SEARCHING = $F5AF         ; "SEARCHING FOR ..."  (checks MSGFLG $9D)
STOCK_LOADING   = $F5D2         ; "LOADING"/"VERIFYING" (checks MSGFLG $9D)

        .segment "KLOAD"

; --- stock KERNAL entries this code calls -----------------------------------
LISTEN   = $FFB1
SECOND   = $FF93
CIOUT    = $FFA8
UNLSN    = $FFAE
FNLEN    = $B7
SA       = $B9
FNADR    = $BB                  ; $BB/$BC
EAL      = $AE                  ; $AE/$AF: end address, what LOAD returns

; Scratch. $9E/$9F are the stock KERNAL's tape error-log pointers -- dead with
; the tape code they belonged to. They must not be $FB-$FE: the Epyx sender uses
; those, and neither may be X, which _epyx_send_byte clobbers.
KLIDX    = $9E                  ; chunk number, across CIOUT's X clobber

.import _epyx_send_begin, _epyx_send_byte, _epyx_send_op, _epyx_send_end
.import _epyx_recv_prg

; ILOAD replacement.
; ILOAD replacement. Entry conditions are exactly the stock entry's ($F4A5):
; A = 0 load / 1 verify, and $F49E has already stashed X/Y (the load-address
; override) into $C3/$C4 before its JMP ($0330).
kload_entry:
        sta VERCK
        lda #$00
        sta ST
        lda FA
        beq @illegal                    ; 0 = keyboard
        cmp #$03
        beq @illegal                    ; 3 = screen
        bcc @illegal                    ; 1,2 = tape / RS-232. Tape is what this
                                        ; code replaced, so it cannot be offered
                                        ; -- and it is a non-goal anyway.
        ; --- device 4+: try the fast path ------------------------------------
        ; Every reason not to ends the same way: jump to the stock serial
        ; loader, which is a complete, working LOAD. That is what makes this
        ; patch safe to have in the ROM at all -- the worst case is the speed we
        ; had before.
        lda VERCK
        bne @stock                      ; VERIFY: not implemented here
        lda FNLEN
        beq @noname
        jsr kl_fast
        bcs @stock                      ; upload, header or transfer failed
        ldx EAL                         ; success: LOAD returns the end address
        ldy EAL+1
        clc
        rts
@noname:
        jmp STOCK_NONAME
@illegal:
        jmp STOCK_ILLEGAL
@stock:
        jmp STOCK_SERIAL

; ---------------------------------------------------------------------------
; kl_fast - install the Epyx code in the drive, ask for the file, receive it.
; Carry clear = loaded, end address in $AE/$AF. Carry set = caller falls back.
; ---------------------------------------------------------------------------
kl_fast:
        jsr STOCK_SEARCHING             ; "SEARCHING FOR <name>" -- the stock
                                        ; routine, which checks MSGFLG itself, so
                                        ; a running program still gets silence and
                                        ; direct mode still looks like a C64.
        jsr kl_install
        lda ST
        and #$80
        bne @fail                       ; nobody home on the bus
        jsr kl_header
        bne @fail                       ; drive never signalled ready: not Epyx
        jsr STOCK_LOADING               ; "LOADING" / "VERIFYING", MSGFLG-gated
        jsr _epyx_recv_prg              ; A/X = end address, 0/0 = failure
        sta EAL
        stx EAL+1
        ora EAL+1
        beq @fail
        clc
        rts
@fail:  sec
        rts

; ---------------------------------------------------------------------------
; kl_install - the Epyx fingerprint: three M-W chunks then M-E, over the command
; channel using the stock KERNAL's own IEC routines.
;
; Each chunk is 24 x $EA and one tail byte chosen so the chunk's 8-bit sum is
; what Meatloaf looks for. GENERATED rather than stored: the payload is 75 bytes
; and this is 9, which matters when the whole patch has to fit in 684.
; ---------------------------------------------------------------------------
kl_install:
        lda #$00
        sta KLIDX
@chunk:
        jsr kl_cmd_open
        ldy #$00
@pfx:   lda mw_pfx,y                    ; "M-W"
        jsr CIOUT
        iny                             ; Y survives CIOUT; X does NOT -- the
        cpy #3                          ; stock routine clobbers it, which is why
        bne @pfx                        ; KLIDX is reloaded into X below
        ldx KLIDX
        lda mw_lo,x
        jsr CIOUT
        lda #$01                        ; all three chunks are in page 1
        jsr CIOUT
        lda #25                         ; chunk length
        jsr CIOUT
        ldy #24
@fill:  lda #$EA
        jsr CIOUT
        dey
        bne @fill
        ldx KLIDX
        lda mw_tail,x                   ; the byte that makes the sum match
        jsr CIOUT
        jsr UNLSN
        inc KLIDX
        lda KLIDX
        cmp #3
        bne @chunk
        ; M-E $01A9: run what we just wrote
        jsr kl_cmd_open
        ldy #$00
@me:    lda me_cmd,y
        jsr CIOUT
        iny
        cpy #5
        bne @me
        jmp UNLSN

kl_cmd_open:
        lda FA
        jsr LISTEN
        lda #$6F                        ; channel 15, open
        jmp SECOND

; ---------------------------------------------------------------------------
; kl_header - the Epyx request: the 256-byte op routine (only its checksum is
; read), the name length, then the name BACKWARDS -- the drive reads it into its
; buffer in reverse. Returns Z set if the drive was ready.
; ---------------------------------------------------------------------------
kl_header:
        jsr _epyx_send_begin
        bne @out                        ; never signalled ready
        lda #$86                        ; "V2 load file"
        jsr _epyx_send_op
        lda FNLEN
        jsr _epyx_send_byte
        ldy FNLEN
@name:  dey
        lda (FNADR),y
        jsr _epyx_send_byte             ; clobbers X, leaves Y alone
        cpy #$00
        bne @name
        jsr _epyx_send_end
        lda #$00                        ; Z set: ready
@out:   rts

        .segment "KLDATA"

mw_pfx:  .byte 'M', '-', 'W'
me_cmd:  .byte 'M', '-', 'E', $A9, $01
mw_lo:   .byte $80, $99, $B2            ; $0180, $0199, $01B2
mw_tail: .byte $63, $B6, $9F            ; make the chunk sums $53 / $A6 / $8F

kload_end:
        .export kload_entry, kload_end, kl_fast
