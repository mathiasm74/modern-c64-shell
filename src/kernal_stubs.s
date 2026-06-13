; kernal_stubs.s - standard KERNAL entry points at their published addresses.
;
; Each entry is a JMP into the real implementation, placed by the linker via
; a fixed-start segment (cfg/rom.cfg). External software calls the public
; addresses ($FFBA SETLFS ... $FFE4 GETIN) and lands in our code.
;
; The file-I/O entry points are thin shims over the internal iec_* API in
; iec.s. CBM software passes parameters in CPU registers; the standard KERNAL
; saves them to documented zero-page locations (FA, SA, FNLEN, FNADR, ...)
; which iec_* already reads, so most shims are a register-to-zero-page move
; followed by a JSR. LOAD and SAVE drive the open/read or open/write loop
; themselves.
;
; Single-file model: we don't track per-LFN open-file tables. SETLFS records
; the latest LA/FA/SA and OPEN opens that file; CHKIN/CHKOUT/CLOSE act on
; whichever file is current. Most ML software opens one file at a time.

.import chrout_impl
.import _iec_open, _iec_close, _iec_chkin, _iec_chkout
.import _iec_getbyte, _iec_putbyte, _iec_puteoi
.import _iec_clrchn, _iec_unlisten
.export getin_impl
.export setlfs_impl, setnam_impl
.export open_impl, close_impl
.export chkin_impl, chkout_impl, clrchn_impl, chrin_impl
.export load_impl, save_impl
.export DFLTN, DFLTO, LDTND      ; reset.s initializes these at boot

; --- Zero-page (KERNAL-standard) -----------------------------------------
ST       = $90                   ; I/O status (set by iec_*)
LDTND    = $98                   ; count of open files (0 or 1 in our model)
DFLTN    = $99                   ; default input device (0 = keyboard, >=8 = IEC)
DFLTO    = $9A                   ; default output device (3 = screen, >=8 = IEC)
EAL      = $AE                   ; $AE/$AF: end address / load pointer
SAVPTR   = $A7                   ; $A7/$A8: temp indirect for SAVE's zp arg
LDMODE   = $93                   ; LOAD mode flag: 0 = use file's load addr,
                                 ; nonzero = override with the X/Y argument
KSAVX    = $96                   ; X/Y save slots for entry points that need
KSAVY    = $97                   ; to preserve them across an _iec_* call
WRPEND   = $94                   ; nonzero = a CHROUT byte is buffered for the
                                 ; IEC output channel (the stock $94 BSOUR-flag
                                 ; role); the byte itself is in WRBYTE. The
                                 ; one-byte deferral lets CLRCHN send the FINAL
                                 ; byte with EOI, so the drive finalizes the
                                 ; file instead of leaving a splat.
WRBYTE   = $02BE                 ; the deferred CHROUT byte (page-2 scratch)
STAL     = $C1                   ; $C1/$C2: save start address (resolved from A's zp ptr)
MEMUSS   = $C3                   ; $C3/$C4: LOAD start override (X/Y on entry when SA=0)
LA       = $B8                   ; logical file number (set by SETLFS)
FNLEN    = $B7                   ; filename length
SA       = $B9                   ; secondary address
FA       = $BA                   ; primary (device) address
FNADR    = $BB                   ; $BB/$BC: filename pointer

NDX      = $C6                   ; keyboard buffer count
KEYBUF   = $0277                 ; keyboard buffer

; --- Error codes returned in A (carry set on error) ----------------------
ERR_FILE_NOT_FOUND = $04
ERR_DEVICE_NOT_PRESENT = $05
ERR_LOAD_NOT_LOAD = $0E          ; verify/headerless not implemented

; --- Status bits ---------------------------------------------------------
ST_TIMEOUT = $02
ST_EOI     = $40
ST_NODEV   = $80

.segment "KCODE"                 ; hand-written core in the KERNAL ROM

; -------------------------------------------------------------------------
; getin_impl - return the next character from the keyboard buffer in A, or
; A=0 (Z set) if the buffer is empty. Buffer access is made atomic against
; the IRQ-driven keyboard scan.
; -------------------------------------------------------------------------
getin_impl:
        php
        sei
        lda NDX
        bne @have
        plp
        lda #$00                ; empty: A=0, Z set
        rts
@have:
        ldy KEYBUF              ; character to return
        ldx #$01                ; shift the rest of the buffer down by one
@shift:
        cpx NDX
        bcs @done
        lda KEYBUF,x
        sta KEYBUF - 1,x
        inx
        bne @shift
@done:
        dec NDX
        plp
        tya                     ; A = character (sets Z/N)
        rts

; -------------------------------------------------------------------------
; setlfs_impl - SETLFS: record logical file number, device, secondary.
;   A = logical file number, X = device, Y = secondary
; -------------------------------------------------------------------------
setlfs_impl:
        sta LA
        stx FA
        sty SA
        rts

; -------------------------------------------------------------------------
; setnam_impl - SETNAM: record filename length and pointer.
;   A = length, X = lo byte of name pointer, Y = hi byte
; -------------------------------------------------------------------------
setnam_impl:
        sta FNLEN
        stx FNADR
        sty FNADR+1
        rts

; -------------------------------------------------------------------------
; open_impl - OPEN: open the file described by SETLFS/SETNAM.
; Returns carry clear on success, set on error (A = error code).
; -------------------------------------------------------------------------
open_impl:
        jsr _iec_open
        lda ST
        and #ST_NODEV
        bne @nodev
        lda #$01
        sta LDTND               ; mark one file open
        clc
        rts
@nodev:
        sec
        lda #ERR_DEVICE_NOT_PRESENT
        rts

; -------------------------------------------------------------------------
; close_impl - CLOSE: close the open file. A = LFN on entry (ignored in
; the single-file model -- we close whichever file is current).
; -------------------------------------------------------------------------
close_impl:
        jsr _iec_close
        lda LDTND
        beq @done
        dec LDTND
@done:
        clc
        rts

; -------------------------------------------------------------------------
; chkin_impl - CHKIN: route subsequent CHRIN reads from the open file.
;   X = LFN (ignored: single-file model)
; -------------------------------------------------------------------------
chkin_impl:
        jsr _iec_chkin
        lda ST
        and #ST_NODEV
        bne @nodev
        lda FA
        sta DFLTN               ; future CHRIN -> this device
        clc
        rts
@nodev:
        sec
        lda #ERR_DEVICE_NOT_PRESENT
        rts

; -------------------------------------------------------------------------
; chkout_impl - CHKOUT: route subsequent CHROUT writes to the open file.
;   X = LFN (ignored)
; -------------------------------------------------------------------------
chkout_impl:
        jsr _iec_chkout
        lda ST
        and #ST_NODEV
        bne @nodev
        lda #$00
        sta WRPEND              ; fresh channel: no byte deferred yet
        lda FA
        sta DFLTO
        clc
        rts
@nodev:
        sec
        lda #ERR_DEVICE_NOT_PRESENT
        rts

; -------------------------------------------------------------------------
; chrout_route - CHROUT ($FFD2) front door: route by DFLTO. Screen output
; (DFLTO < 8) goes to chrout_impl as always. With an IEC output channel
; (after CHKOUT), bytes go to the drive -- deferred by one so the last byte
; can be sent with EOI at CLRCHN (the stock KERNAL's buffering contract).
; Preserves A/X/Y per the KERNAL CHROUT contract.
; -------------------------------------------------------------------------
chrout_route:
        pha
        lda DFLTO
        cmp #$08
        bcs @to_iec
        pla
        jmp chrout_impl         ; screen path, unchanged
@to_iec:
        stx KSAVX
        sty KSAVY
        lda WRPEND
        beq @defer              ; first byte: just buffer it
        lda WRBYTE
        jsr _iec_putbyte        ; send the previous byte (more data follows)
@defer:
        pla
        sta WRBYTE
        pha
        lda #$80
        sta WRPEND
        pla
        ldx KSAVX
        ldy KSAVY
        clc
        rts

; -------------------------------------------------------------------------
; clrchn_impl - CLRCHN: restore default I/O channels (keyboard in, screen
; out). If an IEC device is currently the input or output channel, also
; release it (UNTALK / UNLISTEN).
; -------------------------------------------------------------------------
clrchn_impl:
        lda DFLTN
        cmp #$08
        bcc @no_in
        jsr _iec_clrchn         ; UNTALK
@no_in:
        lda DFLTO
        cmp #$08
        bcc @no_out
        lda WRPEND
        beq @nopend
        lda #$00
        sta WRPEND
        lda WRBYTE
        jsr _iec_puteoi         ; flush the deferred byte WITH EOI: the drive
                                ; marks end-of-file and CLOSE finalizes it
@nopend:
        jsr _iec_unlisten
@no_out:
        lda #$00
        sta DFLTN               ; -> keyboard
        lda #$03
        sta DFLTO               ; -> screen
        rts

; -------------------------------------------------------------------------
; chrin_impl - CHRIN (BASIN): read one character from the current input.
; From an IEC file: iec_getbyte. From the keyboard: block until a key is
; available, then return it. (Full line-input semantics are BASIC's job.)
;
; Preserves X and Y per the standard KERNAL contract: most ML callers loop
; CHRIN with a register as the counter (e.g. for a buffer index), and the
; underlying _iec_getbyte clears X/Y as part of cc65's fastcall convention.
; -------------------------------------------------------------------------
chrin_impl:
        stx KSAVX
        sty KSAVY
        lda DFLTN
        cmp #$08
        bcc @from_kbd
        jsr _iec_getbyte
@restore:
        ldx KSAVX
        ldy KSAVY
        rts
@from_kbd:
        jsr getin_impl
        beq @from_kbd           ; block until a key arrives
        jmp @restore

; -------------------------------------------------------------------------
; load_impl - LOAD: read a file into memory.
;   A on entry: 0 = load, !0 = verify (not implemented, returns error).
;   X/Y on entry: low/high of the override load address (used when SA=0).
;   Inputs taken from SETLFS/SETNAM: FA, SA, FNLEN, FNADR.
; Returns: carry clear on success, A = 0; X/Y = end address (one past the
;   last byte stored). On error: carry set, A = error code.
;
; SA semantics: SA=0 -> ignore the file's first 2 bytes (its embedded load
;   address) and write starting at X/Y. SA=1 -> use the file's first 2
;   bytes as the start address (the BASIC RUN convention; most ML loaders).
; -------------------------------------------------------------------------
load_impl:
        cmp #$00
        beq @do_load
        sec
        lda #ERR_LOAD_NOT_LOAD  ; verify / other modes not supported
        rts
@do_load:
        stx MEMUSS              ; save the X/Y override addr (for SA != 0)
        sty MEMUSS+1
        ; The bus side of LOAD always uses channel 0 (the load channel), no
        ; matter what SETLFS recorded as the secondary -- the secondary only
        ; tells *us* whether to honor the file's embedded load address (SA=0,
        ; the BASIC LOAD convention) or to use the X/Y override (SA != 0).
        lda SA
        and #$01
        sta LDMODE
        lda #$00
        sta SA                  ; force bus channel 0 for the open + read
        jsr _iec_open
        lda ST
        and #ST_NODEV
        bne @nodev
        jsr _iec_chkin
        lda ST
        and #(ST_NODEV | ST_TIMEOUT)
        bne @readerr_close
        ; Read the file's first 2 bytes (its own load address)
        jsr _iec_getbyte
        sta EAL
        jsr _iec_getbyte
        sta EAL+1
        lda LDMODE
        beq @stream             ; SA was 0 -> file's address (already in EAL)
        lda MEMUSS               ; SA was non-zero -> override with X/Y
        sta EAL
        lda MEMUSS+1
        sta EAL+1
@stream:
        ; Read bytes until EOI or timeout; store each into (EAL),0 and advance
        jsr _iec_getbyte
        ldy #$00
        sta (EAL),y
        lda ST
        and #(ST_EOI | ST_TIMEOUT)
        bne @stream_done
        inc EAL
        bne @stream
        inc EAL+1
        jmp @stream
@stream_done:
        ; Advance past the last stored byte so EAL = end address (exclusive)
        inc EAL
        bne :+
        inc EAL+1
:
        jsr _iec_clrchn
        jsr _iec_close
        lda ST
        and #ST_TIMEOUT
        bne @readerr
        ; Success: return end address in X/Y, A=0, carry clear
        ldx EAL
        ldy EAL+1
        lda #$00
        clc
        rts
@readerr_close:
        jsr _iec_clrchn
        jsr _iec_close
@readerr:
        sec
        lda #ERR_FILE_NOT_FOUND
        rts
@nodev:
        jsr _iec_close
        sec
        lda #ERR_DEVICE_NOT_PRESENT
        rts

; -------------------------------------------------------------------------
; save_impl - SAVE: write a memory range to a file.
;   A on entry: zero-page address holding the 2-byte start address.
;   X/Y on entry: end address (exclusive) -- low/high.
;   Inputs taken from SETLFS/SETNAM: FA, SA, FNLEN, FNADR.
;
; The first two bytes written to the file are the start address (so the file
; loads back where it came from). The final data byte is sent with EOI.
; Returns carry clear on success, set on error (A = error code).
; -------------------------------------------------------------------------
save_impl:
        ; Stash the end address (X/Y) before we touch any registers.
        stx EAL
        sty EAL+1
        ; A holds an 8-bit zero-page address; the two bytes there are the start
        ; of the save range. 6502 has no `lda zp,y`, so build an indirect.
        sta SAVPTR
        lda #$00
        sta SAVPTR+1
        ldy #$00
        lda (SAVPTR),y
        sta STAL
        iny
        lda (SAVPTR),y
        sta STAL+1
        ; Open and turn around to write
        jsr _iec_open
        lda ST
        and #ST_NODEV
        bne @nodev_close
        jsr _iec_chkout
        lda ST
        and #ST_NODEV
        bne @nodev_close
        ; First two bytes of the file: the start address
        lda STAL
        jsr _iec_putbyte
        lda STAL+1
        jsr _iec_putbyte
@loop:
        ; If STAL >= EAL, we're done
        lda STAL+1
        cmp EAL+1
        bcc @send_one
        bne @done_send
        lda STAL
        cmp EAL
        bcs @done_send
@send_one:
        ldy #$00
        lda (STAL),y
        ; Advance the read pointer; if it now equals EAL we just consumed
        ; the last byte and must send it with EOI.
        pha
        inc STAL
        bne @no_carry
        inc STAL+1
@no_carry:
        lda STAL+1
        cmp EAL+1
        bcc @not_last
        bne @is_last
        lda STAL
        cmp EAL
        bcc @not_last
@is_last:
        pla
        jsr _iec_puteoi
        jmp @done_send
@not_last:
        pla
        jsr _iec_putbyte
        jmp @loop
@done_send:
        jsr _iec_unlisten
        jsr _iec_close
        clc
        lda #$00
        rts
@nodev_close:
        jsr _iec_close
        sec
        lda #ERR_DEVICE_NOT_PRESENT
        rts

; --- fixed-address jump table entries ------------------------------------
.segment "STUB_FILE_IO"          ; linker places this at $FFBA
        jmp setlfs_impl         ; $FFBA SETLFS
        jmp setnam_impl         ; $FFBD SETNAM
        jmp open_impl           ; $FFC0 OPEN
        jmp close_impl          ; $FFC3 CLOSE
        jmp chkin_impl          ; $FFC6 CHKIN
        jmp chkout_impl         ; $FFC9 CHKOUT
        jmp clrchn_impl         ; $FFCC CLRCHN
        jmp chrin_impl          ; $FFCF CHRIN / BASIN

.segment "STUB_CHROUT"           ; linker places this at $FFD2
        jmp chrout_route        ; screen, or the IEC channel set by CHKOUT

.segment "STUB_LOAD_SAVE"        ; linker places this at $FFD5
        jmp load_impl           ; $FFD5 LOAD
        jmp save_impl           ; $FFD8 SAVE

.segment "STUB_GETIN"            ; linker places this at $FFE4
        jmp getin_impl
