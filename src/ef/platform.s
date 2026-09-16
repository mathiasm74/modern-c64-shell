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
        .import chrout_impl, getin_impl, irq_tick
        .import zerobss, copydata
        .import nmi_stub
        .importzp sp

; cc65 force-imports __STARTUP__ from every C module so that SOME startup gets
; linked. reset.s satisfies it on the One ROM build; ef_cold is the startup here,
; and defining it keeps the library's crt0 (with its own idea of the stack and
; the constructor tables) out of the image.
.export __STARTUP__ : absolute
__STARTUP__ = 1
        .export _bank_call, _rbcp_launch_stock
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
        ; Take over the RAM vectors. This is what keeps Tardis looking like
        ; Tardis under a stock KERNAL: our screen code, our keyboard scan, our
        ; encoding -- and $FFD2/$FFE4 route through these, so the banks reach
        ; them too.
        lda #<chrout_impl
        sta $0326
        lda #>chrout_impl
        sta $0327
        lda #<getin_impl
        sta $032A
        lda #>getin_impl
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
        .byte "v0.2.38", 0
ef_brand:
        .byte "Tardis DOS - your C64 power shell", 0
ef_ready:
        .byte "Ready.", 0
; Patched after the link with the real figures (tools/patch_freemem.py); the
; string keeps its length, so the image size is unchanged.
.export ef_freemem
ef_freemem:
        .byte "Free ROM bytes: ROML ---- ROMH ----", 0

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
; void rbcp_launch_stock(void) -- name kept so fs.c does not need an #ifdef.
;
; Where the One ROM build swaps flash sets, plants a CBM80 and resets, this
; writes one register. The program in RAM is untouched and the stock ROMs never
; went anywhere. The write has to happen from RAM, since $8000 stops existing
; the instant it lands.
_rbcp_launch_stock:
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
        sta $8004               ; scrub the CBM80's RAM shadow so the stock reset
        jmp STOCK_RESET         ; does not see a phantom cartridge
ef_kill_end:

; --- the escape hatches c_io.s's run stub expects --------------------------
; On the One ROM build these swap the flash sets back. Here the stock ROMs never
; went away, so "returning to the shell" is one register write -- and phase 3
; deletes most of the stub that calls them, since `run` has nothing to hand over
; to any more.
.export rbcp_escape_tramp, rbcp_nmi_escape
rbcp_nmi_escape:
rbcp_escape_tramp:
        ldx #(ef_back_end - ef_back - 1)
@cp:    lda ef_back,x
        sta EF_RAM,x
        dex
        bpl @cp
        jmp EF_RAM
ef_back:
        lda #MODE_16K
        sta EF_CTRL             ; cartridge visible again from the next fetch
        jmp STOCK_RESET         ; finds our CBM80 and re-enters ef_cold
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
