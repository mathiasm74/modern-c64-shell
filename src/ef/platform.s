; ============================================================================
; platform.s -- the EasyFlash platform layer (PLAN.md section 7, phase 2).
;
; Everything the shell needs that differs between targets. The rest -- shell.c,
; the parser, the commands, screen.s, irq.s, iec.s, the banks -- is shared and
; unchanged, which is the whole point of the port.
;
; Lives in ROML ($8000), the always-mapped half, and must therefore be identical
; in every bank: $DE00 banks BOTH windows, so a "static" half is only static if
; each bank carries the same copy.
;
; Why the stock KERNAL does not fight us: our screen and keyboard code is hooked
; onto the RAM vectors ($0314 IRQ, $0326 BSOUT, $032A GETIN), and the stock
; CHROUT/GETIN entry points vector THROUGH those. So a bank calling $FFD2 --
; every bank does -- lands in our chrout without the bank knowing anything
; changed.
; ============================================================================

EF_BANK  = $DE00
.include "far.inc"              ; far_call's cells
EF_CTRL  = $DE02
EF_RAM   = $DF00

MODE_16K = $87                  ; LED on, MXG=111: ROML $8000 + ROMH $A000
MODE_OFF = $04                  ; LED off, MXG=100: cartridge ROM off

STOCK_RESET = $FCE2
IOINIT   = $FF84
RAMTAS   = $FF87
RESTOR   = $FF8A
CINT     = $FF81

        .import _main
        .import irq_tick
        .import RUN_STUB_BASE   ; c_io.s owns where the run stub runs
        .import RUN_CBM80

EF_KCHROUT = $9FD2              ; pinned by cfg/ef_rom.cfg
EF_KGETIN  = $9FE4
        .import zerobss, copydata
        .import nmi_stub
        .importzp sp

; cc65 force-imports __STARTUP__ from every C module so that SOME startup gets
; linked. reset.s satisfies it on the One ROM build; ef_cold is the startup here,
; and defining it keeps the library's crt0 (with its own idea of the stack and
; the constructor tables) out of the image.
.export __STARTUP__ : absolute
__STARTUP__ = 1
        .export _bank_call, _rbcp_launch_stock, _rbcp_launch_stub
        .export _font_apply, _nv_capability, _nv_read, _nv_write
        .export ef_cold

; ---------------------------------------------------------------------------
        .segment "EFULTIMAX"    ; the tail of bank 0's ROMH: $FF00 in ULTIMAX
; ---------------------------------------------------------------------------
; Where the machine actually starts. At power-on the cart is in Ultimax, so ROMH
; is at $E000-$FFFF and supplies the reset vector -- almost nothing else is
; mapped: no RAM above $0FFF, no stock ROMs.
ef_ultimax:
        sei
        cld
        ldx #$FF
        txs
        lda #$37                ; $01 before $00, per the EF start-up notes
        sta $01
        lda #$2F
        sta $00
        ; The switch cannot happen from here: this code is at $E000-odd BECAUSE
        ; of Ultimax, and the instant $DE02 selects 16K this window becomes the
        ; stock KERNAL. Copy the switch to RAM (Ultimax leaves $0000-$0FFF) and
        ; run it there.
        ldx #(ef_switch_end - ef_switch - 1)
@cp:    lda ef_switch,x
        sta $0200,x
        dex
        bpl @cp
        jmp $0200
ef_switch:
        lda #MODE_16K
        sta EF_CTRL             ; ROML at $8000, stock KERNAL back at $E000
        jmp STOCK_RESET         ; finds our CBM80 at $8004 and enters ef_cold
ef_switch_end:

; ---------------------------------------------------------------------------
        .segment "EFVEC"        ; $FFFA-$FFFF, seen only in Ultimax
; ---------------------------------------------------------------------------
        .word ef_ultimax
        .word ef_ultimax
        .word ef_ultimax

; ---------------------------------------------------------------------------
        .segment "EFBOOT"       ; first in ROML: the CBM80 the stock reset finds
; ---------------------------------------------------------------------------
        .word ef_cold
        .word ef_cold
        .byte $C3, $C2, $CD, $38, $30   ; "CBM80"

ef_cold:
        sei
        cld
        ldx #$FF
        txs
        ; The stock reset checks for a cartridge BEFORE it initialises anything,
        ; so do the init here -- the same list run_stub runs after a One ROM swap.
        jsr IOINIT
        jsr RAMTAS
        jsr RESTOR
        jsr CINT
        jsr ef_screen           ; ...then make it look like Tardis, not stock
        ; Take over the RAM vectors. This is what keeps Tardis looking like
        ; Tardis under a stock KERNAL: our screen code, our keyboard scan, our
        ; encoding -- and $FFD2/$FFE4 route through these, so the banks reach
        ; them too.
        ; Point them at our own PUBLISHED entries ($9FD2/$9FE4, the top-of-ROML
        ; mirror of $FFD2/$FFE4) rather than the implementations behind them,
        ; so the stock $FFD2 -- which is jmp ($0326) -- and the $9FD2 a bank
        ; calls land on exactly the same routing. CHROUT in particular must go
        ; through chrout_route, not straight to the screen: after a bank's
        ; CHKOUT it belongs to the drive.
        lda #<EF_KCHROUT
        sta $0326
        lda #>EF_KCHROUT
        sta $0327
        lda #<EF_KGETIN
        sta $032A
        lda #>EF_KGETIN
        sta $032B
        lda #<ef_irq
        sta $0314
        lda #>ef_irq
        sta $0315
        lda #<nmi_stub          ; RUN/STOP+RESTORE soft-resets, as on the other
        sta $0318               ; target -- and the stock NMI pushes nothing
        lda #>nmi_stub          ; before jmp ($0318), which is exactly the entry
        sta $0319               ; shape nmi_stub was written for.

        ; Bring the cc65 runtime up, exactly as reset.s does on the other
        ; target: point the C software stack somewhere sane, clear BSS, copy the
        ; initialised DATA down from ROM. Without this the C code runs with a
        ; garbage stack pointer and writes over everything -- which is precisely
        ; what the first attempt did.
        lda #<CSTACK_TOP
        sta sp
        lda #>CSTACK_TOP
        sta sp+1
        jsr zerobss
        jsr copydata

        jsr ef_banner
        cli
        jsr _main
@halt:  jmp @halt               ; main() loops forever; trap if it ever returns

; The shell's C stack. $C000-$CFFF is the only RAM this target can keep
; readable state in -- $8000-$9FFF is ROML and pages 0-3 belong to the stock
; KERNAL -- so it is carved up explicitly:
;
;   $C000-$C05F  LINEBUF   (pinned; the completion matcher indexes it)
;   $C060-$C4FF  DATA/BSS  (cfg/ef_rom.cfg)
;   $C500-$C7FF  this C stack, growing down from CSTACK_TOP
;   $C800-$CDFF  the served bank's DATA/BSS/C stack (cfg/ef_*_bank.cfg)
;   $CE00-$CFFF  the filename completion cache, and run_stub at $CF00
CSTACK_TOP = $C800              ; grows down through $C7xx-$C5xx

; ---------------------------------------------------------------------------
        .segment "EFCODE"
; ---------------------------------------------------------------------------

; --- the screen, the way reset.s sets it up on the other target -------------
; CINT leaves the machine looking like a stock C64: blue on blue, and $D018 =
; $15, the UPPERCASE/graphics charset. Tardis runs the LOWERCASE/text charset --
; that is what makes its whole encoding ASCII-consistent (pet2scr maps 'a' to
; screen code $01), so without this the shell would come up in the wrong font
; and every lowercase letter it printed would be a graphic.
;
; It has to run AFTER CINT, which writes $D018 and fills colour RAM itself.
ef_screen:
        lda #MEMPTR_0400
        sta $D018
        lda #CTRL2_40COL
        sta $D016
        lda #COLOR_LTRED
        sta $D020
        lda #COLOR_RED
        sta $D021
        lda #COLOR_WHITE
        sta $0286               ; text colour for everything drawn from here
        ; CINT filled colour RAM with its own light blue; the screen is already
        ; blank, so repaint the colour nybbles to match what we draw in.
        ldx #$00
@col:   sta $D800 + $000,x
        sta $D800 + $100,x
        sta $D800 + $200,x
        sta $D800 + $2E8,x      ; tail: covers through $DBE7
        inx
        bne @col
        rts

MEMPTR_0400 = $16               ; screen @ $0400, lowercase/text charset @ $1800
CTRL2_40COL = $C8
COLOR_WHITE = $01
COLOR_RED   = $02               ; background (dark red), as reset.s boots to
COLOR_LTRED = $0A               ; border (light red)

; --- the startup banner ----------------------------------------------------
; reset.s draws this straight into screen RAM because on the One ROM build it
; runs BEFORE the display is enabled and before CHROUT is usable. Here CINT has
; already run and our chrout is on $0326, so the banner is just printing --
; which also keeps the layout honest (the cursor ends where main() wants it).
;
; Rows match the other target: 0 version (right-aligned to col 38), 2 brand,
; 4 free bytes, 6 "Ready.", then main()'s prompt on row 8.
ef_banner:
        ldx #(39 - 7)           ; right-align the 7-char version
@pad:   lda #' '
        jsr $FFD2
        dex
        bne @pad
        lda #<ef_version
        ldx #>ef_version
        jsr ef_puts
        jsr ef_crlf
        lda #' '
        jsr $FFD2
        lda #' '
        jsr $FFD2
        lda #' '
        jsr $FFD2
        lda #<ef_brand
        ldx #>ef_brand
        jsr ef_puts
        jsr ef_crlf
        lda #' '
        jsr $FFD2
        lda #<ef_freemem
        ldx #>ef_freemem
        jsr ef_puts
        jsr ef_crlf
        lda #<ef_ready
        ldx #>ef_ready
        jsr ef_puts
        jmp ef_crlf

ef_crlf:
        lda #$0D
        jsr $FFD2
        lda #$0D
        jmp $FFD2

; A/X = string pointer; prints to the NUL. The pointer goes through zero page,
; NOT a self-modified operand: this runs from flash, where a store lands in the
; RAM underneath and the fetch still comes from ROM. (reset.s uses the same
; $FB-$FE scratch for the same job on the other target.)
EF_SRC = $FB                    ; free ZP under the stock KERNAL
ef_puts:
        sta EF_SRC
        stx EF_SRC+1
        ldy #$00
@loop:  lda (EF_SRC),y
        beq @done
        jsr $FFD2
        iny
        bne @loop
@done:  rts

ef_version:
        .byte "v0.3.16", 0
ef_brand:
        .byte "Tardis DOS - your C64 power shell", 0
ef_ready:
        .byte "Ready.", 0
; Patched after the link with the real figures (tools/patch_freemem.py); the
; string keeps its length, so the image size is unchanged. It names the halves
; as the One ROM banner does: BASIC is ROMH bank 0 (the shell) and KERNAL is
; ROML (the always-mapped half), so the two targets' boot screens read alike.
.export ef_freemem
ef_freemem:
        .byte "Free ROM bytes: BASIC ---- KERNAL ----", 0

; --- the IRQ, arriving the stock way --------------------------------------
; $FF48 has already pushed A/X/Y and dispatched through $0314, so this must NOT
; save them again and must leave through $EA81 (pull A/X/Y, RTI) rather than
; RTI'ing on a frame that is not its own.
ef_irq:
        jsr irq_tick
        jmp $EA81

; --- bank_call ------------------------------------------------------------
; unsigned char __fastcall__ bank_call(unsigned char entry)
;
; A = bank id in the high 3 bits, entry index in the low 5 -- the same encoding
; the One ROM build uses, so the dispatch table and every bank are unchanged.
; Returns 0 if the bank ran, non-zero if it could not be mapped.
;
; Three register writes where the One ROM build spends ~588us of protocol.
;
; This runs from ROML, which $DE00 banks along with ROMH -- so it only survives
; the switch because EVERY bank carries a byte-identical ROML (tools/make_ef_crt
; packs it that way). Break that and the CPU's next fetch after `sta EF_BANK`
; comes from a different image at the same address.
_bank_call:
        ldx #0                  ; a command is never inside a far call; page 3
        stx FAR_DEPTH           ; is garbage at power-on (src/far.inc)
        pha
        ; Plant the "jsr <bank entry> / rts" stub in the cartridge's RAM first;
        ; the copy is free to use A and X because the argument is on the stack.
        ldx #(ef_gosub_end - ef_gosub - 1)
@cp:    lda ef_gosub,x
        sta EF_RAM,x
        dex
        bpl @cp
        pla
        pha
        and #$1F                ; A = entry index
        sta EF_RAM + 1
        asl a                   ; entry*2 (entry <= 31, so no carry out)
        clc
        adc EF_RAM + 1          ; entry*3 -- the JMP table's stride
        clc
        adc #<BANK_ENTRY
        sta EF_RAM + 1          ; patch the stub's operand
        pla
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a                   ; A = bank id
        clc
        adc #EF_FIRST_BANK      ; ROMH bank 0 is the shell itself
        sta EF_BANK
        ; Verify we got the bank we asked for before calling into it: $A000 must
        ; read "bnk". Without this a wrong bank number runs whatever is there --
        ; and an ABSENT bank reads $FF, which is what the flash gives back.
        lda $A000
        cmp #'b'
        bne @fail
        lda $A001
        cmp #'n'
        bne @fail
        lda $A002
        cmp #'k'
        bne @fail
        jsr EF_RAM              ; -> jsr $A0xx -> rts, from cartridge RAM
        lda #$00
        beq @done
@fail:  lda #$05                ; "bank unavailable"
@done:  pha
        lda #$00
        sta EF_BANK             ; back to bank 0: the shell
        pla
        ldx #$00
        rts

BANK_ENTRY  = $A004             ; the bank ABI's JMP table

; --- far_call -------------------------------------------------------------
; A running bank calls a SERVICE entry in another bank (SVC 13, src/far.inc):
; Y = (bank << 5) | entry, A/X = the one argument; A/X = the result, or $FFFF.
; The One ROM version (src/rbcp/launch.s) has the full story. Here mapping is a
; $DE00 write, so the caller is re-served by writing its bank back -- which
; bank_call's "back to 0" could not do.
;
; The caller is whatever $A003 says: this is only reachable from a bank, and
; bank_call checked that bank's identity before calling in. The entry goes
; through an indirect JMP on a page-3 vector, which is not self-modifying code,
; so it can run from ROML and leaves bank_call's $DF00 stub alone.
.export far_call
far_call:
        sta FAR_ARG
        stx FAR_ARG+1
        lda FAR_DEPTH
        bne @refuse             ; one level only, as on the One ROM
        inc FAR_DEPTH
        lda BANK_ENTRY - 1      ; $A003: the caller's bank id
        sta FAR_CALLER
        tya
        and #$1F                ; entry
        sta FAR_VEC
        asl a
        clc
        adc FAR_VEC             ; entry*3
        clc
        adc #<BANK_ENTRY
        sta FAR_VEC
        lda #>BANK_ENTRY
        adc #0
        sta FAR_VEC+1
        tya
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a                   ; A = the callee's bank id
        pha
        clc
        adc #EF_FIRST_BANK
        sta EF_BANK
        pla
        cmp BANK_ENTRY - 1      ; identity: "bnk" and the id we asked for
        bne @fail
        lda $A000
        cmp #'b'
        bne @fail
        lda $A001
        cmp #'n'
        bne @fail
        lda $A002
        cmp #'k'
        bne @fail
        lda FAR_ARG
        ldx FAR_ARG+1
        jsr @go
        sta FAR_ARG
        stx FAR_ARG+1
@back:  lda FAR_CALLER
        clc
        adc #EF_FIRST_BANK
        sta EF_BANK
        dec FAR_DEPTH
        lda FAR_ARG
        ldx FAR_ARG+1
        rts
@fail:  lda #$FF
        sta FAR_ARG
        sta FAR_ARG+1
        bne @back               ; always
@refuse:
        lda #$FF
        tax
        rts
@go:    jmp (FAR_VEC)

; The call into the bank cannot be a self-modifying JSR in ROML: the store lands
; in the RAM underneath and the fetch still comes from flash. It runs from the
; cartridge's own $DF00 RAM instead -- 256 bytes that stay visible in every mode
; and every bank, which is exactly what this needs. (The One ROM build has the
; same indirection; there it is a RAM trampoline at $C800.)
ef_gosub:
ef_gosub_op:
        jsr BANK_ENTRY          ; low byte patched above
        rts
ef_gosub_end:

EF_FIRST_BANK = 1               ; ROMH bank 0 is the shell; banks start at 1

; --- leaving to stock ------------------------------------------------------
; Two ways out, both a single register write. Names kept so fs.c needs no
; #ifdef -- the platform difference lives here, which is the point.
;
; void rbcp_launch_stub(void): hand over to the run stub at $CF00, which sets
; the machine up for stock BASIC (IOINIT/RAMTAS/RESTOR/CINT, then the program).
; The One ROM build has to plant a CBM80 and reset, because it only arrives
; through the stock reset vector. Here the stock ROMs never went anywhere and
; RAM is untouched, so turning the cart off and jumping is the whole thing --
; no CBM80, no reset, no RESTOR fragility.
;
; ORDER MATTERS: the cart must be off BEFORE the stub runs, because the stub
; calls RAMTAS, whose non-destructive test walks up to $A000. With ROML still
; mapped at $8000-$9FFF the readback would come from flash, RAMTAS would decide
; RAM ends at $8000, and BASIC would come up with 8K less memory.
_rbcp_launch_stub:
        jsr ef_arm_escape       ; last chance: we are about to unmap ourselves
        ; Nothing plants a CBM80 on this target, so tell the stub not to
        ; "consume" one. The flag is ordinary RAM and powers up as garbage --
        ; left to chance it would scrub $8004, which here is a byte of the
        ; loaded program rather than a signature we put there.
        lda #$00
        sta RUN_CBM80
        ldx #(ef_to_stub_end - ef_to_stub - 1)
@cp:    lda ef_to_stub,x
        sta EF_RAM,x
        dex
        bpl @cp
        jmp EF_RAM

ef_to_stub:
        lda #MODE_OFF
        sta EF_CTRL
        jmp RUN_STUB_BASE
ef_to_stub_end:

; void rbcp_launch_stock(void): a bare cold swap -- `basic` with nothing
; loaded. Straight into the stock reset, which gives a fresh BASIC.
_rbcp_launch_stock:
        jsr ef_arm_escape
        ldx #(ef_kill_end - ef_kill - 1)
@cp:    lda ef_kill,x
        sta EF_RAM,x
        dex
        bpl @cp
        jmp EF_RAM

ef_kill:
        lda #MODE_OFF
        sta EF_CTRL
        lda #$00
        sta $8004               ; nothing plants a CBM80 on this target, but
                                ; $8000 is ordinary RAM with the cart off, so
        jmp STOCK_RESET         ; scrub it rather than risk a phantom cartridge
ef_kill_end:

; --- the escape hatches c_io.s's run stub expects --------------------------
; The run stub writes these two addresses into $0318 (NMI, so RUN/STOP+RESTORE
; comes home) and $0302 (IMAIN, so a program that exits to READY does too).
;
; They CANNOT be addresses in ROML. The stub writes them and then the cartridge
; is switched off -- from that moment $8000-$9FFF is ordinary RAM holding
; whatever the loaded program put there, so both vectors would point into
; garbage and RUN/STOP+RESTORE would crash instead of returning to the shell.
;
; So they live in the cartridge's own $DF00 RAM, which the spec keeps visible in
; every mode INCLUDING with the ROM off -- the one piece of the cartridge that
; survives its own disappearance, and exactly what it is there for. The symbols
; are absolute: the stub stores the RAM address, not ours.
.export rbcp_escape_tramp, rbcp_nmi_escape
EF_ESCAPE        = EF_RAM + $40         ; clear of bank_call's stub at $DF00
rbcp_escape_tramp = EF_ESCAPE
rbcp_nmi_escape   = EF_ESCAPE

; Install it. Called by both launch entries before the cartridge goes away --
; there is no later chance, since afterwards this code is not mapped either.
ef_arm_escape:
        ldx #(ef_back_end - ef_back - 1)
@cp:    lda ef_back,x
        sta EF_ESCAPE,x
        dex
        bpl @cp
        rts
ef_back:
        lda #MODE_16K
        sta EF_CTRL             ; cartridge visible again from the next fetch
        jmp STOCK_RESET         ; finds our CBM80 at $8004 and re-enters ef_cold
ef_back_end:

; --- features with no EasyFlash equivalent ---------------------------------
; The One ROM serves a character ROM as a third chip and keeps settings in NV
; flash. A cartridge does neither. Report failure rather than pretend: `font`
; already prints "font switch unavailable" on this path, and settings_load gates
; everything on nv_capability, so persistence simply stays inert.
_font_apply:
_nv_capability:
_nv_read:
_nv_write:
        lda #$00
        ldx #$00
        rts
