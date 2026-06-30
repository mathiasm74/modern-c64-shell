; about.s - the `about` command, a self-contained multi-page tardis overlay.
;
; NOT in the shell ROM: it lives in the overlays flash set on the One ROM and
; is fetched into $8800 on demand by cmd_about (src/commands/overlay.c) via the
; multi-page SLOT_PEEK loop, the same path edit/files/dir use. Pure assembly --
; it clears the screen and prints its embedded text through CHROUT, paginating
; with a "-- more --" prompt every screenful, then RTSes.
;
; Header (must be the first bytes at the overlay base $8800):
;   +0  jmp start    entry point the resident thunk calls
;   +3  "abt1"       cache-validation magic the thunk checks
;   +7  page count   total 256-byte pages, computed from the link symbols

CHROUT = $FFD2
GETIN  = $FFE4
CLEAR  = $93
CR     = $0D
PAGE_LINES = 22                 ; lines per screen before "-- more --"
PTR     = $FB                   ; free scratch zp (reset's string ptrs, idle now)
LINECNT = $FD

.import __OVL_START__, __OVL_LAST__

.segment "CODE"

        jmp start
        .byte "abt1"
        .byte <((__OVL_LAST__ - __OVL_START__ + $FF) / $100)
start:
        lda #CLEAR              ; fresh screen so the text starts at the top
        jsr CHROUT
        lda #0
        sta LINECNT
        lda #<msg
        sta PTR
        lda #>msg
        sta PTR+1
@loop:
        ldy #0
        lda (PTR),y
        beq @done
        jsr CHROUT
        cmp #CR
        bne @adv               ; only line ends (CR) advance the page counter
        inc LINECNT
        lda LINECNT
        cmp #PAGE_LINES
        bcc @adv               ; still room on this screen
        jsr advance_ptr        ; step past this CR, then peek what follows
        ldy #0
        lda (PTR),y
        beq @done              ; text ends here -> no pointless "-- more --"
        jsr more               ; prompt, wait for a key, clear, reset counter
        jmp @loop
@adv:
        jsr advance_ptr
        jmp @loop
@done:
        rts

advance_ptr:
        inc PTR
        bne @ap
        inc PTR+1
@ap:
        rts

; "-- more --", wait for any key, clear the screen, reset the line counter.
more:
        ldx #0
@mp:
        lda moremsg,x
        beq @wait
        jsr CHROUT
        inx
        bne @mp
@wait:
        jsr GETIN
        cmp #0
        beq @wait              ; no key yet
        lda #CLEAR
        jsr CHROUT
        lda #0
        sta LINECNT
        rts
moremsg:
        .byte "-- more --", 0

; Each line ends in CR; a lone CR is a blank line between paragraphs. Lines are
; <= 39 chars: a 40-char line fills the row, the cursor auto-wraps, and then the
; CR adds a SECOND line break (a stray blank line) -- so keep them under 40.
; EXCEPTION: a line that is EXACTLY 40 chars may omit its CR -- the auto-wrap is
; then the line break, and the next CR (here the paragraph blank) lands cleanly.
; The "...OneROM chip." line below uses this to fill the row without an orphan.
msg:
        .byte "TARDIS DOS", CR
        .byte CR
        .byte "This shell with a modern feel is built", CR
        .byte "specifically for legacy C64 hardware", CR
        .byte "upgraded with @piers.rocks' OneROM chip."   ; 40 cols, NO CR (see above)
        .byte CR
        .byte "A single 24-pin OneROM then serves both", CR
        .byte "the BASIC and KERNAL sockets. The", CR
        .byte "original 2x 8KB is much too little for", CR
        .byte "anything but the literal basics, but", CR
        .byte "the OneROM offers a way around this;", CR
        .byte "while some code lives in ROM, most is", CR
        .byte "streamed as needed through a small", CR
        .byte "address ", $22, "window", $22, ". This essentially makes"   ; 40 cols, NO CR (see above)
        .byte "the ROM bigger on the inside than the", CR
        .byte "outside, just like the Doctor's TARDIS.", CR
        .byte CR
        .byte "While in the Tardis shell, none of the", CR
        .byte "original BASIC or KERNAL is present -", CR
        .byte "so legacy software can't run directly.", CR
        .byte "Thus, on calling RUN (or inserting a", CR
        .byte "cartridge), the OneROM hot-swaps ROMs to"   ; 40 cols, NO CR (see above)
        .byte "the stock C64 ones before launching the", CR
        .byte "program.", CR
        .byte CR
        .byte "Tardis DOS is the ideal companion to", CR
        .byte "the Meatloaf device, which it accesses", CR
        .byte "with built-in Epyx fast loading.", CR
        .byte CR
        .byte "Made by Mathias Malmqvist with Claude", CR
        .byte "Code in 2026.", CR
        .byte 0
