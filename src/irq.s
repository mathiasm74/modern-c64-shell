; irq.s - Phase 3 interrupt handler and keyboard scan.
;
; CIA #1 timer A fires ~60 times a second. The handler acknowledges it,
; advances the jiffy clock, and scans the keyboard matrix, pushing decoded
; PETSCII into the keyboard buffer. NMI is still just an RTI stub.

.export irq_handler
.export nmi_stub

; --- CIA #1 -------------------------------------------------------------
CIA1_PRA  = $DC00       ; keyboard column select (output)
CIA1_PRB  = $DC01       ; keyboard row read (input)
CIA1_ICR  = $DC0D       ; reading acknowledges the timer interrupt

; --- jiffy clock and keyboard state (KERNAL-compatible) -----------------
TIME      = $A0         ; $A0/$A1/$A2: 24-bit jiffy counter
LSTX      = $C5         ; matrix code of the last key seen ($FF = none)
NDX       = $C6         ; number of characters in the keyboard buffer
KEYBUF    = $0277       ; keyboard buffer, 10 bytes
KEYBUF_MAX = 10

COLMASK   = $F7         ; scan scratch (not used by the main thread / CHROUT)
ROWBITS   = $F8
found_key = $F9         ; matrix code found this scan ($FF = none)
SHFLAG    = $028D       ; nonzero while a SHIFT key is held this scan
RPTCNT    = $028C       ; key-repeat countdown: initial delay, then rate

KEY_DELAY = 30          ; ticks a key is held before it starts repeating (~0.5s)
KEY_RATE  = 4           ; ticks between repeats once repeating (~15/s)

; Hand-written core lives in the KERNAL ROM ($E000); the cc65-emitted shell
; owns the default CODE segment in the BASIC ROM ($A000). See cfg/rom.cfg.
.segment "KCODE"

; -------------------------------------------------------------------------
; irq_handler - timer tick: ack, advance jiffy clock, scan keyboard.
; -------------------------------------------------------------------------
irq_handler:
        pha
        txa
        pha
        tya
        pha

        lda CIA1_ICR            ; acknowledge CIA #1 (clears the IRQ line)

        inc TIME+2              ; advance the 24-bit jiffy clock
        bne @scan
        inc TIME+1
        bne @scan
        inc TIME
@scan:
        jsr scan_keyboard

        pla
        tay
        pla
        tax
        pla
        rti

nmi_stub:
        rti

; -------------------------------------------------------------------------
; scan_keyboard - walk the 8x8 matrix, decode one pressed key to PETSCII,
; and push it into the keyboard buffer. Simple debounce: a key is emitted
; once when first pressed (no auto-repeat); shift keys are skipped.
; -------------------------------------------------------------------------
scan_keyboard:
        lda #$FF
        sta found_key           ; assume nothing pressed
        lda #$00
        sta SHFLAG              ; clear shift (bit0) and cbm (bit1) flags
        ldx #$00                ; matrix code 0..63
        lda #$FE                ; walking-zero column select, starting PA0
        sta COLMASK
@col:
        lda COLMASK
        sta CIA1_PRA            ; drive one column low
        lda CIA1_PRB            ; read the 8 rows (0 = pressed)
        sta ROWBITS
        ldy #$08
@row:
        lsr ROWBITS             ; next row bit -> carry
        bcs @next               ; 1 = not pressed
        cpx #15
        beq @shift              ; left shift
        cpx #52
        beq @shift              ; right shift
        cpx #61
        beq @cbmkey             ; CBM (Commodore) key
        cpx #58
        beq @ctrlkey            ; CTRL key (a modifier, like the stock KERNAL)
        stx found_key           ; remember this key (last pressed wins)
        jmp @next
@shift:
        lda SHFLAG
        ora #$01                ; bit0 = a shift key is held
        sta SHFLAG
        jmp @next
@cbmkey:
        lda SHFLAG
        ora #$02                ; bit1 = the CBM key is held
        sta SHFLAG
        jmp @next
@ctrlkey:
        lda SHFLAG
        ora #$04                ; bit2 = CTRL held (matches stock $028D layout)
        sta SHFLAG
@next:
        inx
        dey
        bne @row
        sec
        rol COLMASK             ; rotate the 0 to the next column (brings in 1)
        cpx #64
        bcc @col

        ldx found_key
        cpx #$FF
        beq @none               ; nothing pressed this scan
        cpx LSTX
        beq @held               ; same key still held -> maybe auto-repeat
        stx LSTX                ; new key: emit it and arm the initial delay
        lda #KEY_DELAY
        sta RPTCNT
        jmp @lookup
@held:
        dec RPTCNT
        bne @ret                ; not time to repeat yet
        lda #KEY_RATE           ; repeat now, then again after the rate
        sta RPTCNT
@lookup:
        lda SHFLAG
        and #$04                ; CTRL held?
        bne @viactrl
        lda SHFLAG
        and #$01                ; shift held?
        bne @shifted
        lda SHFLAG
        and #$02                ; CBM held?
        bne @viacbm
        lda keytab,x            ; unshifted decode
        jmp @emit
@viactrl:
        ; CTRL+letter emits the ASCII control code ($01-$1A), nano-style:
        ; ^k = $0B, ^x = $18, ... and ^i = $09 keeps TAB (and so the shell's
        ; tab completion) reachable. CTRL with a non-letter emits the plain
        ; unshifted character.
        lda keytab,x
        cmp #'a'
        bcc @emit               ; below 'a': emit as-is
        cmp #'z'+1
        bcs @emit               ; above 'z': emit as-is
        and #$1F                ; fold to the control code
        jmp @emit
@shifted:
        lda keytab_shift,x      ; shifted decode: uppercase, !"#$ symbols,
        jmp @emit               ; <>?[] punctuation, cursor left/up, CLR, ...
@viacbm:
        ; VICE's symbolic keymap sends host '_' as @+CBM (the only CBM combo
        ; it uses); decode that one to underscore and ignore the rest.
        cpx #46                 ; the @ key
        bne @ret
        lda #$5F                ; underscore
@emit:
        beq @ret                ; non-emitting key (ctrl, a shift/cbm alone, ...)
        ldx NDX
        cpx #KEYBUF_MAX
        bcs @ret                ; buffer full
        sta KEYBUF,x
        inc NDX
        rts
@none:
        lda #$FF
        sta LSTX                ; released -> next press will register
@ret:
        rts

; -------------------------------------------------------------------------
; keytab / keytab_shift - matrix code (0-63) -> ASCII/PETSCII. $00 = key
; produces no char. Standard C64 matrix order. Letter keys deliver LOWERCASE
; (the boot default is the lowercase charset); SHIFT selects keytab_shift,
; which gives uppercase letters and the C64-native shifted symbols.
;
; The shifted symbols are deliberately the *native* C64 layout (shift-1 = !,
; shift-2 = ", ... shift-6 = &, shift-/ = ?, shift-: = [, shift-; = ]). That
; is what VICE's default symbolic keyboard mapping expects: it translates a
; host symbol to the C64 key+shift that natively makes it, so a host '!'
; arrives as shift-1 and must decode to '!'. (Symbols the C64 makes with a
; dedicated key -- @ * + and the up-arrow for ^ -- come through those keys
; unshifted and are already in keytab.) keytab_shift is exported so a test
; can check the table bytes; the matrix scan itself is GUI-verified.
; -------------------------------------------------------------------------
.export keytab
.export keytab_shift

keytab:
        .byte $14,$0D,$1D,$88,$85,$86,$87,$11   ; DEL RET CR> F7 F1 F3 F5 CR\/
        .byte $33,$77,$61,$34,$7A,$73,$65,$00   ; 3 w a 4 z s e LSHIFT
        .byte $35,$72,$64,$36,$63,$66,$74,$78   ; 5 r d 6 c f t x
        .byte $37,$79,$67,$38,$62,$68,$75,$76   ; 7 y g 8 b h u v
        .byte $39,$69,$6A,$30,$6D,$6B,$6F,$6E   ; 9 i j 0 m k o n
        .byte $2B,$70,$6C,$2D,$2E,$3A,$40,$2C   ; + p l - . : @ ,
        .byte $5C,$2A,$3B,$13,$00,$3D,$5E,$2F   ; POUND * ; HOME RSHIFT = ^ /
        .byte $31,$5F,$00,$32,$20,$00,$71,$03   ; 1 <- CTRL(mod) 2 SPC CBM q STOP

; SHIFTed decode, same matrix order. Cursor right/down become left/up ($9D/
; $91); HOME becomes CLR ($93). Punctuation/symbol keys with no useful shifted
; ASCII (+ - @ * = ^ £ <-) keep their unshifted value.
keytab_shift:
        .byte $14,$0D,$9D,$8C,$89,$8A,$8B,$91   ; DEL RET CRSR-L F8 F2 F4 F6 CRSR-U
        .byte $23,$57,$41,$24,$5A,$53,$45,$00   ; # W A $ Z S E LSHIFT
        .byte $25,$52,$44,$26,$43,$46,$54,$58   ; % R D & C F T X
        .byte $27,$59,$47,$28,$42,$48,$55,$56   ; ' Y G ( B H U V
        .byte $29,$49,$4A,$30,$4D,$4B,$4F,$4E   ; ) I J 0 M K O N
        .byte $2B,$50,$4C,$2D,$3E,$5B,$40,$3C   ; + P L - > [ @ <
        .byte $5C,$2A,$5D,$93,$00,$3D,$5E,$3F   ; POUND * ] CLR RSHIFT = ^ ?
        .byte $21,$5F,$00,$22,$20,$00,$51,$03   ; ! <- CTRL(mod) " SPC CBM Q STOP
