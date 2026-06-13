; reset.s - Phase 1 boot: take full control of the machine.
;
; Bring the C64 to a clean, deterministic state under our own control instead
; of relying on stock KERNAL behavior: set the processor port memory map,
; quiet both CIAs (timers stopped, interrupts masked), initialize the VIC-II,
; clear the screen, and draw a startup banner. No interrupts are enabled and
; there is no keyboard input yet -- that arrives in Phase 3.

.import irq_handler
.import nmi_stub
.import set_line_ptrs
.import pet2scr                 ; ASCII -> screen code (shared with CHROUT)
.import iec_init                ; serial bus port setup
.import _rbcp_launch_stock      ; RBCP: swap the One ROM to the stock ROMs
.importzp DFLTN, DFLTO, LDTND   ; default I/O channels (kernal_stubs.s)

; --- cc65 C runtime: entry point, startup helpers, and the data-stack ptr --
.import _main                   ; the C shell (src/shell.c)
.import zerobss                 ; clear the BSS segment in RAM
.import copydata                ; copy initialized DATA from ROM to RAM
.importzp sp                    ; cc65 C software stack pointer
.import __RAM_START__, __RAM_SIZE__

; cc65 force-imports __STARTUP__ from every C module to guarantee a startup
; module gets linked. We are that startup (see below), so define the symbol
; ourselves; this keeps the library's crt0 -- and the constructor/destructor
; machinery it pulls in -- out of the ROM. The value is never used.
.export __STARTUP__ : absolute  ; cc65 imports it as absolute; match that
__STARTUP__ = 1

.export reset

; --- Processor port ------------------------------------------------------
CPU_DDR    = $00
CPU_PORT   = $01

; --- Screen / color RAM --------------------------------------------------
SCREEN_RAM = $0400              ; 1000 text cells
COLOR_RAM  = $D800              ; 1000 color nybbles

; --- VIC-II --------------------------------------------------------------
VIC_CTRL1  = $D011              ; DEN, RSEL, YSCROLL, ...
VIC_CTRL2  = $D016              ; CSEL, XSCROLL, MCM
VIC_MEMPTR = $D018              ; screen / charset base
VIC_BORDER = $D020
VIC_BGCOL  = $D021

; --- CIA #1 ($DC00) and CIA #2 ($DD00) -----------------------------------
CIA1_PRA   = $DC00              ; keyboard column select (output)
CIA1_PRB   = $DC01              ; keyboard row read (input)
CIA1_DDRA  = $DC02
CIA1_DDRB  = $DC03
CIA1_TALO  = $DC04              ; timer A latch low/high
CIA1_TAHI  = $DC05
CIA1_ICR   = $DC0D              ; interrupt control/status
CIA1_CRA   = $DC0E              ; timer A control
CIA1_CRB   = $DC0F              ; timer B control
CIA2_PRA   = $DD00              ; port A (low 2 bits select VIC bank)
CIA2_DDRA  = $DD02
CIA2_ICR   = $DD0D
CIA2_CRA   = $DD0E
CIA2_CRB   = $DD0F

; --- Zero-page scratch (documented-free bytes; see CLAUDE.md) -------------
zp_src     = $FB                ; $FB/$FC: source pointer for puts_at
zp_dst     = $FD                ; $FD/$FE: screen destination pointer

; --- Cursor / text color (shared with screen.s) --------------------------
PNTR       = $D3                ; cursor column
TBLX       = $D6                ; cursor row
COLOR      = $0286              ; current text color

; --- Keyboard state (shared with irq.s) ----------------------------------
LSTX       = $C5                ; matrix code of the last key ($FF = none)
NDX        = $C6                ; keyboard buffer count

; --- Constants -----------------------------------------------------------
COLOR_BLACK  = $00
COLOR_WHITE  = $01              ; text and cursor color
COLOR_BLUE   = $06
COLOR_LTBLUE = $0E              ; classic C64 default text color
SPACE        = $20              ; screen code for a blank cell

CPU_DDR_STD  = $2F              ; port bits 0-5 are outputs
CPU_PORT_STD = $37              ; shell ROM ($A000) + KERNAL ROM ($E000) + I/O

CTRL1_BLANK  = $0B              ; 25 rows, text mode, display OFF
CTRL1_ON     = $1B              ; same, display ON
CTRL2_40COL  = $C8              ; 40 columns
MEMPTR_0400  = $16              ; screen @ $0400, lowercase/text charset @ $1800
TIMER_PERIOD = $4025            ; CIA #1 timer A latch (~60 Hz IRQ tick)

; Write a zero-terminated ASCII string `str` to screen address `dst`.
; The parentheses matter: ca65's #< / #> byte operators bind tighter than +,
; so `#>dst` without them would compute (>base)+offset, not >(base+offset).
.macro PRINT str, dst
        lda #<(str)
        sta zp_src
        lda #>(str)
        sta zp_src+1
        lda #<(dst)
        sta zp_dst
        lda #>(dst)
        sta zp_dst+1
        jsr puts_at
.endmacro

.segment "KCODE"                ; hand-written core in the KERNAL ROM (see cfg/rom.cfg)

reset:
        sei                     ; mask IRQs during setup
        cld                     ; binary arithmetic
        ldx #$ff
        txs                     ; reset the stack pointer

        ; --- Processor port: lock in our memory map ----------------------
        ; Write the data latch ($01) BEFORE the DDR ($00). If we made bits 0-2
        ; outputs first, they would drive the latch's reset value (0), pulling
        ; LORAM/HIRAM/CHAREN low and instantly unmapping the KERNAL ROM we are
        ; executing from -- the next instruction fetch would come from garbage.
        ; Writing the latch while the bits are still inputs is harmless (pull-
        ; ups keep the ROMs mapped); the DDR write then drives the right value.
        lda #CPU_PORT_STD
        sta CPU_PORT            ; latch = $37 (shell ROM + KERNAL ROM + I/O)
        lda #CPU_DDR_STD
        sta CPU_DDR             ; bits 0-5 outputs; now driving the latched $37

        ; --- Blank the display while we set up ---------------------------
        lda #CTRL1_BLANK
        sta VIC_CTRL1

        ; --- CIAs: stop timers, mask and clear all interrupts ------------
        ; SEI does not block NMIs, and CIA #2 drives the NMI line, so masking
        ; here is what actually guarantees a quiet machine.
        lda #$7f
        sta CIA1_ICR            ; disable all CIA #1 interrupt sources
        sta CIA2_ICR            ; disable all CIA #2 interrupt sources
        lda CIA1_ICR            ; read to clear any pending flags
        lda CIA2_ICR
        lda #$00
        sta CIA1_CRA            ; stop CIA #1 timers A/B
        sta CIA1_CRB
        sta CIA2_CRA            ; stop CIA #2 timers A/B
        sta CIA2_CRB

        ; --- Boot ROM selector: hold C= for the stock ROMs --------------
        ; Read the Commodore (C=) key directly (keyboard column PA7, row PB5)
        ; before anything is drawn. Held at power-on -> switch the One ROM to the
        ; stock C64 ROMs (via RBCP) instead of booting the shell. (A cartridge is
        ; the other stock-swap trigger, but that check is deferred until after the
        ; screen/IEC init -- see "Cartridge auto-detect" below -- to give a Kung
        ; Fu Flash time to present its cart and to ride out the One ROM/cart boot
        ; race that otherwise left the screen black when we swapped too early.)
        ; Boot-time keyboard scan after Holger Gryska's MIT-licensed
        ; c64-bootloader (derived from EasyFlash's crt0). On a shell-only build
        ; the RBCP call is inert and the launcher falls through (FFFC) to the shell.
        lda #$ff
        sta CIA1_DDRA           ; keyboard columns = outputs
        lda #$00
        sta CIA1_DDRB           ; keyboard rows = inputs
        lda #$7f
        sta CIA1_PRA            ; drive column PA7 low
        ldx #$10                ; let the key matrix settle
@kb_settle:
        dex
        bne @kb_settle
        lda CIA1_PRB            ; read rows; C= is bit 5
        and #$20
        bne @boot_shell         ; C= not held -> boot the shell
        jmp _rbcp_launch_stock  ; C= held -> stock ROMs (never returns)
@boot_shell:

        ; --- VIC-II memory layout, bank, and colors ----------------------
        lda #MEMPTR_0400
        sta VIC_MEMPTR
        lda #CTRL2_40COL
        sta VIC_CTRL2
        lda CIA2_DDRA
        ora #$03
        sta CIA2_DDRA           ; bank-select bits are outputs
        lda CIA2_PRA
        ora #$03                ; %......11 -> VIC bank 0 ($0000-$3FFF)
        sta CIA2_PRA
        lda #COLOR_BLACK
        sta VIC_BORDER
        lda #COLOR_BLUE
        sta VIC_BGCOL

        ; --- Clear screen to spaces, color RAM to light blue -------------
        ldx #$00
        lda #SPACE
@clrscr:
        sta SCREEN_RAM + $000,x
        sta SCREEN_RAM + $100,x
        sta SCREEN_RAM + $200,x
        sta SCREEN_RAM + $2E8,x ; tail: covers through $07E7
        inx
        bne @clrscr

        ldx #$00
        lda #COLOR_WHITE
@clrcol:
        sta COLOR_RAM + $000,x
        sta COLOR_RAM + $100,x
        sta COLOR_RAM + $200,x
        sta COLOR_RAM + $2E8,x
        inx
        bne @clrcol

        ; --- Startup banner ----------------------------------------------
        PRINT banner1, SCREEN_RAM + 40 * 1 + 1
        PRINT banner2, SCREEN_RAM + 40 * 3 + 1

        ; --- Keyboard port: PA outputs (columns), PB inputs (rows) -------
        lda #$ff
        sta CIA1_DDRA
        sta CIA1_PRA            ; no column driven yet
        lda #$00
        sta CIA1_DDRB

        ; --- Keyboard state: empty buffer, no key held -------------------
        lda #$00
        sta NDX
        lda #$FF
        sta LSTX

        ; --- Default I/O channels: keyboard in, screen out, no files open
        lda #$00
        sta DFLTN               ; input = keyboard
        sta LDTND               ; no files open
        lda #$03
        sta DFLTO               ; output = screen

        ; --- CIA #1 timer A: continuous, ~60 Hz, IRQ on underflow --------
        lda #<TIMER_PERIOD
        sta CIA1_TALO
        lda #>TIMER_PERIOD
        sta CIA1_TAHI
        lda #$81
        sta CIA1_ICR            ; enable timer A interrupt
        lda #$11
        sta CIA1_CRA            ; start, continuous mode, force-load latch

        ; --- Cursor: a couple of lines below the banner ------------------
        lda #COLOR_WHITE
        sta COLOR
        lda #$00
        sta PNTR
        lda #$05
        sta TBLX
        jsr set_line_ptrs

        ; --- Serial bus: drive ATN/CLK/DATA, release the lines -----------
        jsr iec_init

        ; --- Enable the display now that the screen is ready -------------
        lda #CTRL1_ON
        sta VIC_CTRL1

        cli                     ; allow the timer IRQ (keyboard scan) to run

        ; --- Cartridge auto-detect (deferred from the early C= check) -----
        ; A cartridge at $8000 carrying the CBM80 signature ($C3,$C2,$CD,$38,$30
        ; at $8004-$8008) -- e.g. a game on a Kung Fu Flash -- hands the machine
        ; to the stock ROMs, whose KERNAL then does the CBM80 autostart. We check
        ; HERE, after the full screen/IEC init, rather than at the early C= check:
        ; a KFF needs time after power-on to present its cart, and the banner
        ; becomes briefly visible before the swap. Our KERNAL can't run cartridge
        ; software itself (it expects stock KERNAL routines).
        ;
        ; The swap stops our CIA IRQ timer first (see launch.s) so the game
        ; doesn't inherit a live timer it never armed -- stock's cartridge-
        ; autostart path skips the IOINIT/CINT that would otherwise clean up.
        ;
        ; Postmortem of the long flakiness hunt (games starting then going
        ; black, varying run to run): it was NOT this swap. The cause was a
        ; Meatloaf on the IEC bus interfering with cartridge games -- it
        ; reproduced on a pure-stock-ROM firmware with no shell and no swap
        ; (`make onerom-pure-stock-flash`), and unplugging the Meatloaf fixed
        ; it. Games blank the screen while loading, so a wedged IEC handshake
        ; presents as a black screen. If cart games go black at game start,
        ; unplug IEC devices before suspecting this code.
        lda $8004
        cmp #$C3
        bne @no_cart
        lda $8005
        cmp #$C2
        bne @no_cart
        lda $8006
        cmp #$CD
        bne @no_cart
        lda $8007
        cmp #$38
        bne @no_cart
        lda $8008
        cmp #$30
        bne @no_cart
        jmp _rbcp_launch_stock  ; cartridge present -> stock ROMs (never returns)
@no_cart:

        ; --- Hand control to the C shell ---------------------------------
        ; cc65 expects its data stack pointer initialized to one past the top
        ; of the C stack (it grows downward); BSS zeroed and DATA copied from
        ; ROM to RAM before main() runs.
        lda #<(__RAM_START__ + __RAM_SIZE__)
        sta sp
        lda #>(__RAM_START__ + __RAM_SIZE__)
        sta sp+1
        jsr zerobss
        jsr copydata
        jsr _main               ; the shell loops forever; should not return
@halt:
        jmp @halt               ; trap, just in case main() ever returns

; -------------------------------------------------------------------------
; puts_at: copy the zero-terminated ASCII string at (zp_src) to screen RAM
; at (zp_dst), converting ASCII to C64 screen codes via pet2scr (the same
; mapping CHROUT uses), so mixed-case banners render correctly. Clobbers A
; and Y; pet2scr preserves Y across the call.
; -------------------------------------------------------------------------
puts_at:
        ldy #$00
@loop:
        lda (zp_src),y
        beq @done               ; NUL terminator
        jsr pet2scr
        sta (zp_dst),y
        iny
        bne @loop
@done:
        rts

banner1:
        .byte "C64 Shell ROM v0.15", 0
banner2:
        .byte "Ready.", 0

; --- 6502 hardware vectors ($FFFA-$FFFF) ---------------------------------
.segment "VECTORS"
        .addr nmi_stub          ; $FFFA NMI
        .addr reset             ; $FFFC RESET
        .addr irq_handler       ; $FFFE IRQ/BRK
