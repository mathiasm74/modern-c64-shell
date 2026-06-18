; about.s - the `about` command, a self-contained multi-page tardis overlay.
;
; NOT in the shell ROM: it lives in the overlays flash set on the One ROM and
; is fetched into $8800 on demand by cmd_about (src/commands/overlay.c) via the
; multi-page SLOT_PEEK loop, the same path edit/files/dir use. Pure assembly --
; it clears the screen and prints its embedded text through CHROUT, then RTSes.
;
; Header (must be the first bytes at the overlay base $8800):
;   +0  jmp start    entry point the resident thunk calls
;   +3  "abt1"       cache-validation magic the thunk checks
;   +7  page count   total 256-byte pages, computed from the link symbols

CHROUT = $FFD2
CLEAR  = $93
CR     = $0D
PTR    = $FB                    ; free scratch zp (reset's string ptr, idle now)

.import __OVL_START__, __OVL_LAST__

.segment "CODE"

        jmp start
        .byte "abt1"
        .byte <((__OVL_LAST__ - __OVL_START__ + $FF) / $100)
start:
        lda #CLEAR              ; fresh screen so the text starts at the top
        jsr CHROUT
        lda #<msg
        sta PTR
        lda #>msg
        sta PTR+1
@loop:
        ldy #0
        lda (PTR),y
        beq @done
        jsr CHROUT
        inc PTR
        bne @loop
        inc PTR+1
        jmp @loop
@done:
        rts

; Each line ends in CR; a lone CR is a blank line between paragraphs. Lines are
; <= 40 chars so they don't wrap; the whole thing is ~one screen after CLEAR.
msg:
        .byte "Tardis DOS - a command shell for the", CR
        .byte "Commodore 64, in place of BASIC and", CR
        .byte "KERNAL. Named for Doctor Who's TARDIS,", CR
        .byte "the 16K ROM is bigger on the inside.", CR
        .byte CR
        .byte "It runs from a OneROM, a flash cart that", CR
        .byte "serves the C64's ROM sockets. Bigger", CR
        .byte "commands - editor, file tools, this", CR
        .byte "about text - stay on the cart as", CR
        .byte "overlays and load into RAM on demand,", CR
        .byte "so the shell does far more than 16K.", CR
        .byte CR
        .byte "Disk reads drive the IEC bus directly.", CR
        .byte "Programs can load through an Epyx-", CR
        .byte "compatible fast loader, far quicker", CR
        .byte "than the stock KERNAL.", CR
        .byte CR
        .byte "font swaps the charset and keyboard", CR
        .byte "together, so the C64 speaks more than", CR
        .byte "one language - English and Swedish.", CR
        .byte "run starts a program on the stock ROMs.", CR
        .byte CR
        .byte "Made by Mathias Malmqvist with Claude", CR
        .byte "Code, 2026.", CR
        .byte 0
