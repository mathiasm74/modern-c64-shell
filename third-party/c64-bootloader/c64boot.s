; C64 Boot Code for One ROM Image Selection Menu

; Copyright (C) 2026 Holger Gryska <r107sl@web.de>
; MIT License
;
; Derived from EasyFlash 3 boot code crt0.s
; Copyright (c) 2012-2021 Thomas Giesel
;
; This software is provided 'as-is', without any express or implied
; warranty.  In no event will the authors be held liable for any damages
; arising from the use of this software.
; Permission is granted to anyone to use this software for any purpose,
; including commercial applications, and to alter it and redistribute it
; freely, subject to the following restrictions:

; The origin of this software must not be misrepresented; you must not
; claim that you wrote the original software. If you use this software
; in a product, an acknowledgment in the product documentation would be
; appreciated but is not required.
; Altered source versions must be plainly marked as such, and must not be
; misrepresented as being the original software.
; This notice may not be removed or altered from any source distribution.

.include "zeropage.inc"
.include "c64.inc"
.include "rbcp_defs.inc"

.export _exit
.export __STARTUP__ : absolute = 1      ; mark as startup
.import __RAM_START__, __RAM_SIZE__
.import __RAMCODE_LOAD__, __RAMCODE_RUN__, __RAMCODE_SIZE__

.import rbcp_reset
.import rbcp_cmd_enter_cmd_resp
.import rbcp_cmd_get_ram_slot_info_all
.import rbcp_cmd_get_flash_slot_info_all
.import rbcp_cmd_load_slot
.import rbcp_cmd_switch_and_exit
.import rbcp_cmd_get_device_type, rbcp_cmd_get_device_version
.import rbcp_check_protocol_version
.import rbcp_cmd_get_nv_capability
.import rbcp_cmd_nv_peek, rbcp_cmd_nv_poke_commit_byte

.import _main
.import initlib, donelib, copydata
.import zerobss
.import BSOUT

.segment "ZEROPAGE"
; cc65 uses zeropage $02-$1A and RBCP library $F0-$FF
_nrSets:       .res 1   ; number of available ROM sets 
_selSet:       .res 1   ; selected ROM set
_nrVect:       .res 1   ; number of selected Kernal vector
_destVect:     .res 2   ; pointer to selected Kernal vector
_savePC:       .res 2   ; save PC of previous JSR instruction
_error:        .res 1   ; RBCP protocol error counter and flag

.export _nrSets, _selSet, _error

; -----------------------------------------------------------------------------
.segment "CODE"

coldStart:              ; C64 reset vector points here
        sei             ; disable interrupts
        ldx #$ff
        txs             ; intialize stack pointer
        cld
        stx _nrVect     ; source of Kernal vector jmp ($ff for reset)
        
        lda #$08
        sta VIC_CTRL2   ; enable VIC (e.g. RAM refresh)

        ; write RAM to make sure it starts up correctly (see RAM datasheets)
        lda #$00
startWait:
        sta $0100,x
        dex
        bne startWait
kernalStart:
        sei             ; disable interrupts

        ; copy RBCP related code to RAM (256 byte blocks)
        lda #<__RAMCODE_LOAD__
        sta CURS_X
        lda #>__RAMCODE_LOAD__
        sta CURS_X+1
        lda #<__RAMCODE_RUN__
        sta CURS_Y
        lda #>__RAMCODE_RUN__
        sta CURS_Y+1
        ldx #>(__RAMCODE_SIZE__ + 255)
        ldy #$00        ; intialize page index
@loop:
        lda (CURS_X),y
        sta (CURS_Y),y
        iny
        bne @loop
        inc CURS_X+1
        inc CURS_Y+1
        dex
        bne @loop
        
        lda #10         ; initialise RBCP init error retrial counter
        sta _error
        jsr initOneROM  ; initialize One ROM
        lda _error
        bne bootMenu    ; display error message
        
        lda #$7f        ; prepare the CIA to scan the keyboard
        sta $dc00       ; pull down row PA7

        ldx #$ff
        stx $dc02       ; DDRA $ff = output
        inx
        stx $dc03       ; DDRB $00 = input

        lda $dc01       ; read keyboard columns PBx for row PA7

        ; restore CIA registers to state after hard reset
        stx $dc02       ; DDRA input again
        stx $dc00       ; no row pulled down

        and #$e0        ; if "Run/Stop", "Q" or "C=" is pressed
        cmp #$e0
        bne bootMenu

        jmp activateROM ;   boot One ROM with previously selected ROM set

bootMenu:
        jsr initNoKernal  ; further C64 initialization

        lda #<(__RAM_START__ + __RAM_SIZE__)
        sta sp
        lda #>(__RAM_START__ + __RAM_SIZE__)
        sta sp + 1      ; set cc65 argument stack pointer

        jsr zerobss     ; clear cc65 BSS segment
        jsr copydata    ; initialize cc65 DATA segment
        jsr initlib     ; run cc65 constructors
        
        jsr readOneROM  ; read One ROM data for boot menu
        jsr _main       ; call main.c

_exit:  jsr donelib     ; run cc65 destructors
        
        jmp rememberROM ; save & activate selected ROM and return to C64

; -----------------------------------------------------------------------------
.segment "RAMCODE"      ; this code is copied to the RAM area

initOneROM:
        jsr rbcp_reset  ; reset One ROM
        jsr rbcp_cmd_enter_cmd_resp  ; setup and enter command-response mode
        bcc @prtcl
        dec _error
        bne initOneROM  ; retrial loop in case of an error
        lda #1          ; failed to enter rbcp cmd-resp
        jmp @exit
@prtcl: lda #0          ; initialize RBCP error flag with $00
        sta _error
        jsr rbcp_check_protocol_version  ; check RBCP protocol version
        lda #2          ; wrong rbcp protocol version
        bcs @exit
        lda #1
        sta rbcp_arg0
        lda #0
        sta rbcp_arg1
        sta rbcp_arg2
        jsr rbcp_cmd_nv_peek  ; peek previous flash slot selection byte
        bcs @error
        lda RBCP_DATA_ADDR    ; load stored flash slot selection byte
        beq @error      ; check for invalid $00
        cmp #$ff
        bne @ok         ; if flash uninitialized
        lda #1          ;   load ROM image slot 1 as default
@ok:    sta _selSet     ; selSet contains previously selected ROM image slot
        rts
@error: lda #3          ; load previous selection failed
@exit:  sta _error
        rts
        
readOneROM:
        jsr rbcp_cmd_get_flash_slot_info_all
        lda #4          ; rbcp get flash slot info failed
        bcs @error
        ldx RBCP_DATA_ADDR + 1
        cpx #2
        lda #5          ; no kernal found to boot
        bcc @error
        stx _nrSets     ; remember number of available ROM sets
        jsr rbcp_cmd_get_device_version
        bcc @ok
        lda #6          ; rbcp get device version failed
@error: sta _error
@ok:    rts
        
rememberROM:        
        lda _selSet     ; load select flash slot
        sta rbcp_arg0
        lda #0
        sta rbcp_arg1
        sta rbcp_arg2
        lda #1          ; select RAM slot 1 for staging
        sta rbcp_arg3
        jsr rbcp_cmd_nv_poke_commit_byte  ; poke selected flash slot
        
activateROM:
        lda #1          ; select RAM slot 1
        ldx _selSet     ; select ROM image slot
        jsr rbcp_cmd_load_slot  ; copy ROM image into RAM
        bcc @ok
        jmp kernalStart
@ok:    lda #1          ; select RAM slot 1
        jsr rbcp_cmd_switch_and_exit  ; activate RAM slot & exit command-resp mode

        lda _nrVect     ; identify source of jump to boot menu
        bmi @reset      ; $ff for reset
        lda _savePC+1
        pha             ; restore PC high byte on stack
        lda _savePC
        pha             ; restore PC low byte on stack
        jmp (_destVect) ; continue selected Kernal routine
@reset: 
        jmp (resetVector) ; C64 reset

; -----------------------------------------------------------------------------
.segment "CODE"

initNoKernal:
        lda #$7f
        sta CIA1_ICR    ; kill interrupts
        sta CIA2_ICR
        sta CIA1_PRA    ; turn on stop key
        lda #$08
        sta CIA1_CRA    ; shut off timers
        sta CIA2_CRA
        sta CIA1_CRB
        sta CIA2_CRB
        ldx #$00
        stx CIA1_DDRB   ; initialize keyboard inputs
        stx CIA2_DDRB   ; initialize userport (no RS232)
        stx SID_Amp     ; switch off SID
        dex
        stx CIA1_DDRA   ; initialize keyboard outputs
        lda #$07
        sta CIA2_PRA    ; set serial/va14/15 (clkhi)
        lda #$3f
        sta CIA2_DDRA   ; set serial in/out, va14/15out
        
        lda #$e7        ; 6510 port output register:
        sta $0001       ; set motor on, hiram lowram charen high
        lda #$2f        ; 6510 data direction register:
        sta $0000       ; set motor out, sw in, wr out, control
        
        ldx #47         ; initialize all VIC registers (screen disabled)
@loop:  lda tvic-1,x
        sta VIC-1,x
        dex
        bne @loop
        
        rts
        
tvic:   .byt 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0       ; sprites (0-16)
        .byt $8b,$37,0,0,0,$08,0,$17,$0f,0,0,0,0,0,0 ; data (17-31)
        .byt 0,0,1,2,3,4,0,1,2,3,4,5,6,7             ; regs 32-46

dummyVector:
        dec $d020
        jmp dummyVector
        
skipIRQ:
        rti
        
kernalCatch:
        sta _nrVect     ; save number of selected Kernal vector
        asl
        adc _nrVect     ; multiply number by 3
        adc #$81        ; calculate Kernal vector low byte
        sta _destVect   ; store Kernal vector low byte
        lda #$ff
        sta _destVect+1 ; store Kernal vector high byte
        pla
        sta _savePC     ; save source PC low byte
        pla
        sta _savePC+1   ; save source PC high byte
        jmp kernalStart
        
CINT:   lda #0
        jmp kernalCatch
IOINIT: lda #1
        jmp kernalCatch
        
; -----------------------------------------------------------------------------
.segment "JMPTBL"       ; catch JMP from Ultimax cartridges to Kernal routines

        jmp CINT
        jmp IOINIT
RAMTAS: jmp dummyVector
RESTOR: jmp dummyVector
VECTOR: jmp dummyVector
SETMSG: jmp dummyVector
SECOND: jmp dummyVector
TKSA:   jmp dummyVector
MEMTOP: jmp dummyVector
MEMBOT: jmp dummyVector
SNKEY:  jmp dummyVector
SETTMO: jmp dummyVector
ACPTR:  jmp dummyVector
CIOUT:  jmp dummyVector
UNTLK:  jmp dummyVector
UNLSN:  jmp dummyVector
LISTEN: jmp dummyVector
TALK:   jmp dummyVector
READST: jmp dummyVector
SETLFS: jmp dummyVector
SETNAM: jmp dummyVector
OPEN:   jmp dummyVector
CLOSE:  jmp dummyVector
CHKIN:  jmp dummyVector
CHKOUT: jmp dummyVector
CLRCHN: jmp dummyVector
CHRIN:  jmp dummyVector
CHROUT: jmp dummyVector
LOAD:   jmp dummyVector
SAVE:   jmp dummyVector
SETTIM: jmp dummyVector
RDTIM:  jmp dummyVector
STOP:   jmp dummyVector
GETIN:  jmp dummyVector
CLALL:  jmp dummyVector
UDTIM:  jmp dummyVector
SCREEN: jmp dummyVector
PLOT:   jmp dummyVector
IOBASE: jmp dummyVector

; -----------------------------------------------------------------------------
.segment "VECTORS"

.word   skipIRQ        ; NMI vector
resetVector:
.word   coldStart      ; reset vector
.word   skipIRQ        ; IRQ/BRK vector
