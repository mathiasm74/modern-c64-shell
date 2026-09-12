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
.import _rbcp_launch_bootmenu   ; RBCP: re-serve the C= boot-menu bootloader
.import _nv_read                ; RBCP: read saved settings from NV flash
.import _font_apply             ; RBCP: LOAD_SLOT + SWITCH_SLOT (boot normalize)
.importzp DFLTN, DFLTO, LDTND   ; default I/O channels (kernal_stubs.s)

; --- cc65 C runtime: entry point, startup helpers, and the data-stack ptr --
.import _main                   ; the C shell (src/shell.c)
.import _epyx_gen_descramble    ; fill the RAM Epyx descramble table at boot
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
VIC_IRQ    = $D019              ; interrupt latch (write 1s to acknowledge)
VIC_IRQ_ENA = $D01A             ; interrupt enable (0 = all VIC IRQs off)

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
KBD_LAYOUT = $02CB              ; 0 = US/symbolic tables, 1 = Swedish (irq.s)
BASE_SLOT  = $02CE              ; RAM slot the base set is served from (font A
                                ; = 0, font B = 2); read by bank_restore
LOADADR    = $039A              ; load_start/load_end (disk-bank mailbox)

; --- Constants -----------------------------------------------------------
COLOR_BLACK  = $00
COLOR_WHITE  = $01              ; text and cursor color
COLOR_RED    = $02              ; default background (dark red)
COLOR_BLUE   = $06
COLOR_ORANGE = $08
COLOR_BROWN  = $09
COLOR_LTRED  = $0A              ; default border (light red)
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

        ; --- VIC: disable and clear its interrupt sources ----------------
        ; Our IRQ handler only acks CIA #1 ($DC0D). On a bare C64 the VIC IRQ
        ; is off at power-on, so this was never needed -- but the C128 uses
        ; VIC-IIe raster IRQs in 128 mode, and after GO64 that raster IRQ
        ; carries into C64 mode still enabled. Unacknowledged, it re-fires the
        ; instant the handler returns and livelocks the machine (banner draws,
        ; but main() is starved -> no prompt). Disable all VIC IRQ sources and
        ; clear any pending latch. Harmless on a real C64.
        lda #$00
        sta VIC_IRQ_ENA         ; $D01A: no VIC interrupt sources
        lda #$0F
        sta VIC_IRQ             ; $D019: write 1s to clear any pending latch

        ; --- Normalize the served RAM slot (C= boot-menu bootloader) -----
        ; With r107sl's c64-bootloader as flash set 0, boot goes: bootloader
        ; LOAD_SLOTs the chosen set into RAM slot 1 and serves THAT -- so we
        ; arrive here serving slot 1, with slot 0 still holding the
        ; bootloader image. The shell's slot assumptions (overlay/stock/NV
        ; staging in RAM slot 1, font-A return and escape-to-shell switching
        ; to slot 0) predate the bootloader, so reload our own set into slot
        ; 0 and switch to it. The switch is invisible: slot 0 then carries
        ; the exact bytes the CPU is already fetching (the `font` trick).
        ; On VICE / no One ROM the RBCP handshake fails and this is a no-op.
        ; Must run BEFORE anything that stages into RAM slot 1 -- both the
        ; C= stock-swap just below and the cartridge check's
        ; _rbcp_launch_stock stage there, which must not be the served slot.
        ; TARGET_C128 (defined for the C128 C64-mode build): skip ALL boot-time
        ; RBCP. That firmware has no host-control plugin, and the RBCP command
        ; page ($E000) is the served KERNAL in C64 mode, so a handshake here
        ; hangs before the display is even enabled (white screen + border). The
        ; boot-menu/font/NV features it drives are meaningless there anyway.
.ifndef TARGET_C128
        lda #1
        sta FONT_MB_LOAD                ; LOAD_SLOT first, then SWITCH_SLOT
        sta FONT_MB_FLASH               ; flash set 1 = shell + font A charset
        lda #0
        sta FONT_MB_RAM                 ; into (and switch to) RAM slot 0
        jsr _font_apply
        sei                             ; the trampoline CLIs; stay masked
.endif

        ; --- Boot ROM selector: hold C= for the boot menu ---------------
        ; Read the Commodore (C=) key directly (keyboard column PA7, row PB5)
        ; before anything is drawn. Held -> re-serve the boot-menu bootloader
        ; (flash set 0) and reset into it, so the GRUB-style menu comes back
        ; without a One ROM power cycle. (The One ROM keeps serving the picked
        ; set across a bare C64 reset while it stays powered, so set 0 -- which
        ; normally only runs at One ROM cold boot -- would otherwise be
        ; unreachable; this makes C= = menu from a running shell.) Stock C64 and
        ; JiffyDOS are menu entries, so this replaces the old direct C=->stock
        ; shortcut. (A cartridge still swaps straight to stock -- that check is
        ; deferred until after screen/IEC init, see "Cartridge auto-detect".)
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
        ; Page-2 RAM is uninitialized this early (the normal boot path clears
        ; KBD_LAYOUT much later): a random $01 here would make the swap
        ; trampoline Swedish-patch the stock keyboard tables on ~1/256 cold
        ; boots. Force US before handing off.
        lda #$00
        sta KBD_LAYOUT
.ifndef TARGET_C128
        jmp _rbcp_launch_bootmenu ; C= held -> boot menu (never returns)
.endif
        ; TARGET_C128: C= just falls through to the shell (no RBCP menu swap)
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
        lda #COLOR_LTRED        ; default border (overridden by NV if saved)
        sta VIC_BORDER
        lda #COLOR_RED          ; default background (dark red)
        sta VIC_BGCOL

        ; --- Clear screen to spaces, color RAM to white ------------------
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
        ; row 0: version, right-aligned (7 chars "vX.Y.ZZ" end at col 38)
        ; row 2: brand, centered (33 chars)   row 4: free bytes, centered (38)
        ; row 6: "Ready."   row 7: blank   row 8: the shell prompt (cursor set below)
        PRINT version, SCREEN_RAM + 40 * 0 + 32
        PRINT brand,   SCREEN_RAM + 40 * 2 + 3
        PRINT freemem, SCREEN_RAM + 40 * 4 + 1    ; ROM free bytes (patched in)
        PRINT banner2, SCREEN_RAM + 40 * 6 + 0

        ; --- Keyboard port: PA outputs (columns), PB inputs (rows) -------
        lda #$ff
        sta CIA1_DDRA
        sta CIA1_PRA            ; no column driven yet
        lda #$00
        sta CIA1_DDRB

        ; --- Keyboard state: empty buffer, no key held -------------------
        lda #$00
        sta NDX
        sta $028E               ; CTRL-tap state (irq.s CTRLTAP): page-2 RAM is
                                ; garbage at power-on; 1 would fire a phantom TAB
        sta $02BC               ; IEC probe-mode flag (iec.s PROBEF): garbage
                                ; here would bound every send and falsely drop
                                ; busy drives mid-transfer
        sta $CE00               ; TAB-completion cache valid flag: the $CE00
                                ; page is power-on garbage; a nonzero flag would
                                ; let the first TAB complete from noise
        sta KBD_LAYOUT          ; default to the US/symbolic key tables
        sta BASE_SLOT           ; the base set boots served from RAM slot 0; a
                                ; font switch moves it, and bank_restore
                                ; (launch.s) switches back to whatever this says
        sta LOADADR+0           ; "nothing loaded yet": these four bytes ARE the
        sta LOADADR+1           ; shell's load_start/load_end (the disk-bank
        sta LOADADR+2           ; mailbox, fs.c). Page 3 is power-on garbage, so
        sta LOADADR+3           ; a bare `run` would otherwise launch nonsense
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
        lda #$08                ; prompt on row 8: blank row 7 between "Ready." and it
        sta TBLX
        jsr set_line_ptrs

        ; --- Serial bus: drive ATN/CLK/DATA, release the lines -----------
        jsr iec_init

        ; --- Restore saved colors BEFORE the display turns on ------------
        ; The C settings_load() in main() also restores colors+history, but it
        ; runs after the display is already up, so a saved non-blue scheme would
        ; flash the default blue first. Read just the 6-byte header (magic +
        ; version + 3 colors) from NV here and apply it pre-display. No-op (the
        ; RBCP probe fails fast) on VICE / a non-One-ROM build.
.ifndef TARGET_C128
        jsr restore_colors      ; (skipped for TARGET_C128 -- see above)
.endif

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
.ifndef TARGET_C128
        jmp _rbcp_launch_stock  ; cartridge present -> stock ROMs (never returns)
.endif
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

; --- restore_colors: apply saved border/bg/text from NV before display-on ---
; Reads the 6-byte blob header (magic "TD" + version + 3 colors) and applies
; the colors if valid, so a saved scheme doesn't flash the default blue first.
; A-returns from the NV calls are tested with CMP (the cc65 epilogue's ldx #0
; clobbers the Z flag). The NV trampolines re-enable IRQs, so we SEI again to
; keep reset's setup masked until the main CLI below.
COLORBUF  = $0340               ; 6-byte scratch in the unused tape buffer
NV_MB_LEN = $02C4               ; NV read mailbox (src/rbcp/launch.s)
NV_MB_LO  = $02C5
NV_MB_HI  = $02C6
FONT_MB_LOAD  = $02C8           ; font/normalize mailbox (src/rbcp/launch.s)
FONT_MB_FLASH = $02C9
FONT_MB_RAM   = $02CA
restore_colors:
        ; One RBCP session only: just read the 6-byte header. No separate
        ; capability probe -- it only matters for *writing*, and a failed read
        ; already means "no usable NV". Each NV call re-copies the whole RBCP
        ; library to RAM (~ms), so halving the calls halves the pre-display
        ; delay. (settings_load() in main() still probes capability for saves.)
        lda #6
        sta NV_MB_LEN
        lda #<COLORBUF
        sta NV_MB_LO
        lda #>COLORBUF
        sta NV_MB_HI
        jsr _nv_read
        cmp #0
        bne @rc_done            ; read failed (no NV) -> keep the defaults
        lda COLORBUF+0
        cmp #$54                ; 'T'
        bne @rc_done
        lda COLORBUF+1
        cmp #$44                ; 'D'
        bne @rc_done
        lda COLORBUF+2
        cmp #$03                ; blob version
        bne @rc_done
        lda COLORBUF+3
        and #$0F
        sta VIC_BORDER
        lda COLORBUF+4
        and #$0F
        sta VIC_BGCOL
        lda COLORBUF+5
        and #$0F
        sta COLOR
@rc_done:
        sei                     ; the NV trampolines left IRQs enabled; re-mask
        rts

version:
        .byte "v0.2.20", 0        ; right-aligned, starts col 32 (7 chars, ends col 38)
brand:
        .byte "Tardis DOS - your C64 power shell", 0
banner2:
        .byte "Ready.", 0

; The two "----" fields are patched with the per-ROM free byte counts after the
; link (tools/patch_freemem.py); .export so the patcher can find this string.
.export freemem
freemem:
        .byte "Free ROM bytes: BASIC ---- KERNAL ----", 0

; --- 6502 hardware vectors ($FFFA-$FFFF) ---------------------------------
.segment "VECTORS"
        .addr nmi_stub          ; $FFFA NMI
        .addr reset             ; $FFFC RESET
        .addr irq_handler       ; $FFFE IRQ/BRK
