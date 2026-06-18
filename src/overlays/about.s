; about.s - the first tardis overlay (PLAN.md backlog #4).
;
; This code is NOT in the shell ROM. It lives in the overlays flash slot on
; the One ROM and is fetched into the $CE00 cache page on demand by
; cmd_about (src/commands/overlay.c) via the SLOT_PEEK transport. It proves
; the whole pipeline: a command the 16KB ROM never contained, running from
; lazily-loaded cache RAM.
;
; Overlay rules: linked at $CE00 (cfg/overlay.cfg), entry at the first
; byte, return with RTS. No shell symbols are visible from here -- talk to
; the machine through the fixed KERNAL entry points only.

CHROUT = $FFD2
CR     = $0D

.segment "CODE"

        ldx #0
@loop:
        lda msg,x
        beq @done
        jsr CHROUT
        inx
        bne @loop
@done:
        lda #CR
        jsr CHROUT
        rts

msg:    .byte "TarDOS replaces the C64 BASIC and", CR
        .byte "KERNAL with a shell, disk browser", CR
        .byte "and editor. More commands load on", CR
        .byte "demand from the One ROM. Disk", CR
        .byte "loads use an Epyx loader. 'font'", CR
        .byte "switches charset+keyboard between", CR
        .byte "languages. 'run' starts programs.", 0
