; launch.s - RBCP bank-swap launcher.
;
; cmd_runstock calls _rbcp_launch_stock(entry). The flow:
;   1. ROM-side stub copies the whole RBCP_CODE block from KERNAL ROM into
;      RBCP_RAM at $C800, where it's linked to *run* -- this places the
;      library and the in-RAM trampoline at the addresses their internal
;      JSR/JMP/STAs were resolved to.
;   2. Patches the trampoline's final JMP operand with the program's entry.
;   3. JMP into the in-RAM trampoline.
; The trampoline (in RBCP_CODE so it's a part of the copy) then does:
;   SEI -> rbcp_reset -> enter_cmd_resp -> load_slot -> switch_and_exit
; and finally JMPs to the patched entry. After switch_and_exit the device is
; serving the stock-ROM slot; the JMP lands in the program's territory under
; the new ROM map.
;
; This file deliberately uses no cc65 runtime: no software stack, no zero-page
; pseudo-regs that might collide with the library's $80-$8F block.

.export _rbcp_launch_stock
.export rbcp_trampoline               ; exported for tests / inspection only

.include "rbcp_defs.s"          ; constants only (ZP/arg locations, addresses)

.import rbcp_reset
.import rbcp_cmd_enter_cmd_resp
.import rbcp_cmd_load_slot
.import rbcp_cmd_switch_and_exit
.import rbcp_cmd_slot_peek
.import rbcp_cmd_exit_cmd_resp
.import rbcp_cmd_get_nv_capability, rbcp_cmd_nv_peek
.import rbcp_cmd_nv_poke_begin, rbcp_cmd_nv_poke
.import rbcp_cmd_nv_poke_commit, rbcp_cmd_nv_poke_discard
.import rbcp_cmd_switch_slot     ; live char-ROM (font) switch
.import rbcp_cmd_slot_poke       ; patch bytes into a loaded slot (Swedish kbd)

; Where the library sits in ROM (load) and runs (run); both defined by ld65
; when the RBCP_CODE segment has `define = yes`.
.import __RBCP_CODE_LOAD__
.import __RBCP_CODE_RUN__
.import __RBCP_CODE_SIZE__

; RBCP indexes by loadable ROM SET (plugin slots don't count). With the
; C= boot-menu bootloader as loadable set 0, the order is: 0 bootloader,
; 1 shell (font A), 2 stock, 3 JiffyDOS, 4/5 overlays_a/b, 6 shell font B,
; 7 overlays_c (cfg/onerom-stock.json). We load stock into a RAM slot the
; device isn't serving and switch to it. (Serving is RAM slot 0 for font A
; after the boot normalize in reset.s, or slot 2 for font B -- never 1.)
.ifdef TARGET_C128
; C128 firmware layout: 0 Tardis (served), 1/2/3 overlays_a/b/c, 4 stock C64.
; `basic`/`run` swap to that stock C64 set (the 325182-style [BASIC][KERNAL]
; 16KB image) so C64 mode becomes real stock C64 BASIC.
RBCP_STOCK_FLASH_SLOT = 4
.else
RBCP_STOCK_FLASH_SLOT = 2
.endif
RBCP_STOCK_RAM_SLOT   = 1

; The C= boot-menu bootloader is loadable ROM set 0 (r107sl's c64-bootloader,
; served at One ROM cold boot). _rbcp_launch_bootmenu re-serves it so holding C=
; from a running shell returns to the menu -- without a One ROM power cycle,
; which is otherwise the only thing that re-runs set 0 (the device keeps serving
; the last-picked set across a bare C64 reset while it stays powered).
RBCP_BOOTMENU_FLASH_SLOT = 0
RBCP_BOOTMENU_RAM_SLOT   = 1

; Keyboard layout flag the shell maintains (irq.s / cmd_font): 0 = US, 1 =
; Swedish. Page-2 RAM, so it survives into the swap trampoline. When 1, the
; trampoline patches the stock KERNAL's keyboard decode tables in the loaded
; (not-yet-served) stock slot so stock BASIC/KERNAL scans the Swedish layout.
KBD_LAYOUT = $02CB

; Scratch in the gap above iec.s's $A9 SECADR and below the KERNAL's $B7
; FNLEN. Used only inside _rbcp_launch_stock (which never returns).
copy_src = $AB
copy_dst = $AD
copy_len = $AF

; --- Boot-trace stamps (debug): build with `make TRACE=1` -----------------
; Border-color stamps around each swap stage; $D020 shows even while the
; display is blanked, so on hardware the lingering color names the stage
; eating the boot time:
;   red       = trampoline entered (device reset pending)
;   orange    = device reset done, entering command-respond mode
;   yellow    = command-respond mode entered, LOAD_SLOT pending
;   green     = stock set loaded into the RAM slot, switching + handoff
;   blue      = switch sent, stock KERNAL booting (lingers through its init,
;               until stock CINT repaints the border light blue)
;   light red = LOAD_SLOT failed -> booting back into the shell
.macro TRACE_BORDER color
.ifdef RBCP_BOOT_TRACE
        lda #color
        sta $D020
.endif
.endmacro

; =========================================================================
; ROM-side stub. Runs from KERNAL ROM ($Exxx); copies the RBCP code into RAM
; and hands off. Never returns.
; =========================================================================
.segment "KCODE"

_rbcp_launch_stock:
        ; No arguments. The trampoline hands off through (FFFC) -- the stock
        ; KERNAL reset vector -- so there's nothing to patch on the way in.
        ; Once we want a planted-CBM80-style autostart, we'll bring back an
        ; entry argument and patch a JMP in the trampoline.

        ; --- Quiet our IRQ source before swapping ------------------------
        ; If we're swapping from the running shell (the late cartridge-detect
        ; path, or runstock) our CIA1 timer-A IRQ is live. On a real cartridge
        ; boot no timer runs, and the stock KERNAL's cartridge path (JMP $8000)
        ; skips IOINIT, so nothing would stop ours: the first IRQ after the
        ; game's CLI goes through stock's $FF48 -> JMP ($0314) -> uninitialized
        ; RAM. Stop both CIAs' timers and clear pending flags to restore the
        ; real-cart-boot invariant (no IRQ until the game arms its own).
        ; (Harmless on the early C= path, where the timers are already stopped,
        ; and on runstock, where stock's BASIC reset re-inits the CIAs anyway.)
        ;
        ; Note: the game-start flakiness this was added for turned out to be a
        ; Meatloaf on the IEC bus (see the postmortem note in reset.s); this
        ; cleanup is kept because it's correct, not because it was the fix.
        sei
        lda #$7f
        sta $DC0D               ; CIA1 ICR: disable all interrupt sources
        sta $DD0D               ; CIA2 ICR
        lda $DC0D               ; read to clear any pending flags
        lda $DD0D
        lda #$00
        sta $DC0E               ; stop CIA1 timer A
        sta $DC0F               ; stop CIA1 timer B
        sta $DD0E               ; stop CIA2 timer A
        sta $DD0F               ; stop CIA2 timer B

        jsr rbcp_copy_to_ram

        ; Jump into the in-RAM trampoline. From here on we never come back
        ; to ROM-side code (rbcp_trampoline ends in a JMP through (FFFC)).
        jmp rbcp_trampoline

; =========================================================================
; _rbcp_launch_bootmenu - re-serve the boot-menu bootloader (flash set 0) and
; reset into it, so C= from a running shell brings up the menu. Same copy-to-RAM
; + in-RAM trampoline discipline as the stock launcher; never returns. Inert on
; a non-One-ROM build (the RBCP handshake fails and the JMP (FFFC) falls back to
; the shell's own reset -- i.e. a plain reboot).
; =========================================================================
.segment "KCODE"

.export _rbcp_launch_bootmenu
_rbcp_launch_bootmenu:
        ; Reached only from reset.s's early C= check, where both CIAs' timers
        ; are already stopped and IRQs masked -- and the bootloader re-inits the
        ; CIAs itself -- so no CIA-quiet block is needed here (unlike the stock
        ; launcher, which can be entered from the running shell).
        sei
        jsr rbcp_copy_to_ram
        jmp rbcp_bootmenu_tramp

; -------------------------------------------------------------------------
; rbcp_copy_to_ram - copy __RBCP_CODE_SIZE__ bytes from __RBCP_CODE_LOAD__
; (KERNAL ROM) to __RBCP_CODE_RUN__ (RAM), putting the library + trampolines
; at the addresses their internal references were linked for. Idempotent;
; clobbers A/Y and the copy_* zero-page scratch.
; -------------------------------------------------------------------------
rbcp_copy_to_ram:
        lda #<__RBCP_CODE_LOAD__
        sta copy_src
        lda #>__RBCP_CODE_LOAD__
        sta copy_src+1
        lda #<__RBCP_CODE_RUN__
        sta copy_dst
        lda #>__RBCP_CODE_RUN__
        sta copy_dst+1
        lda #<__RBCP_CODE_SIZE__
        sta copy_len
        lda #>__RBCP_CODE_SIZE__
        sta copy_len+1
@copy:
        lda copy_len
        ora copy_len+1
        beq @done
        ldy #0
        lda (copy_src),y
        sta (copy_dst),y
        inc copy_src
        bne :+
        inc copy_src+1
:       inc copy_dst
        bne :+
        inc copy_dst+1
:       lda copy_len
        bne :+
        dec copy_len+1
:       dec copy_len
        jmp @copy
@done:
        rts

; -------------------------------------------------------------------------
; _overlay_fetch_multi - fetch N consecutive overlay pages to an arbitrary
; RAM destination, one RBCP session for the whole run. Parameters go in the
; page-2 mailbox (it must be RAM the library copy doesn't overwrite, and the
; caller sets it BEFORE this is called):
;   OVL_MB_PAGE ($02C0) first overlay page,
;   OVL_MB_CNT  ($02C1) page count (>= 1),
;   OVL_MB_DST  ($02C2) destination page (hi byte; lo is always $00).
; The mailbox is consumed (PAGE/DST step per page, CNT counts down).
; Returns A: 0 = ok, 1 = enter failed, 2 = load failed, 3 = peek failed,
; 4 = exit failed.
; -------------------------------------------------------------------------
.export _overlay_fetch_multi
_overlay_fetch_multi:
        jsr rbcp_copy_to_ram
        jmp rbcp_ovlm_tramp     ; rts there returns to our caller

; =========================================================================
; RAM-side trampoline. Linked into RBCP_CODE so it lives alongside the
; library; after _rbcp_launch_stock's copy it sits in RAM, where it can
; survive the bank swap.
; =========================================================================
.segment "RBCP_CODE"

; -------------------------------------------------------------------------
; rbcp_vic_guard - hold off a command-page send until the VIC-II can't
; interfere. RBCP commands are reads of the $E0xx command page (the byte is
; the address's low bits); when the VIC sets up a badline it drops BA three
; cycles before seizing the bus, and the CPU stalls on its next read cycle
; RE-PRESENTING THE SAME ADDRESS for several ph2 cycles -- which the device
; counts as extra protocol bytes (it cannot deduplicate: frames legitimately
; contain repeated bytes, e.g. ENTER_CMD_RESP's two consecutive $00s). One
; duplicated byte shifts the frame: commands vanish (stage 1), sessions die
; (stage 3), or a SLOT_PEEK with a corrupted offset "succeeds" and returns
; the wrong page (stage 5 bad magic). This was the transport glitch that
; forced overlay.c's 5-attempt retry; the boot-path swap never glitched
; because the display is blanked there (DEN=0 -> no badlines).
;
; Same idea as fastload_recv.s's badline pacing: wait until the raster is
; somewhere a whole command frame (~300 cycles ~= 5 lines) fits before the
; next badline. Assumes YSCROLL=3 ($D011=$1B, the shell's fixed setting) and
; no sprites (the shell uses none). Accepted starts: display blanked, raster
; outside the badline window, or block offsets 4-6 (>= 5 clear lines). The
; $D012 aliasing of PAL lines $100-$137 only ever errs toward waiting.
; Runs from RAM (RBCP_CODE); called by rbcp_knock/rbcp_send_cmd. Clobbers A.
; -------------------------------------------------------------------------
.export rbcp_vic_guard
rbcp_vic_guard:
        lda $D011
        and #$10                        ; DEN off (display blanked)?
        beq @safe                       ; -> no badlines ever, go
@wait:
        lda $D012
        cmp #$2C                        ; well below the window (first badline
        bcc @safe                       ;   is $33; 5-line frame from $2B ends
                                        ;   at $2F/$30 < $33)
        cmp #$F4                        ; past the last badline ($F3)
        bcs @safe
        and #$07
        cmp #4
        bcc @wait                       ; offsets 0-3: on/too close to one
        cmp #7
        bcs @wait                       ; offset 7: not enough clear lines
@safe:
        rts

rbcp_trampoline:
        sei                             ; IRQs would fetch from $E0xx, which
                                        ; is our command page in CR mode -- a
                                        ; spurious read there sends a stray
                                        ; command. Stay masked from now on.
        TRACE_BORDER $02                ; red: entered, device reset pending
        jsr rbcp_reset                  ; reset the device's protocol state
        TRACE_BORDER $08                ; orange: reset done
        jsr rbcp_cmd_enter_cmd_resp     ; enter command-respond mode (the
                                        ; "knock" + handshake)
        TRACE_BORDER $07                ; yellow: in CR mode, loading
        lda #3
        sta copy_len                    ; LOAD_SLOT attempts (zp scratch, free
                                        ; once the ROM->RAM copy has run)
@load:
        lda #RBCP_STOCK_RAM_SLOT
        ldx #RBCP_STOCK_FLASH_SLOT
        jsr rbcp_cmd_load_slot          ; flash slot -> RAM slot (long poll)
        bcc @loaded
        dec copy_len
        bne @load
        ; LOAD_SLOT persistently failed: do NOT switch to a half-copied slot
        ; (that serves garbage -> black screen). Skip the swap instead --
        ; (FFFC) still points into the shell ROM, so this boots back to the
        ; shell prompt; landing there instead of BASIC IS the failure signal.
        TRACE_BORDER $0A                ; light red: load failed, no swap
        jmp ($FFFC)
@loaded:
        TRACE_BORDER $05                ; green: slot loaded, switching

        ; --- Swedish keyboard under stock ROMs --------------------------------
        ; If font B (Swedish) is active, patch the stock KERNAL's keyboard decode
        ; tables in the just-loaded (not-yet-served) slot so stock BASIC/KERNAL
        ; scans the Swedish layout. The tables are at $EB81 (unshift) / $EBC2
        ; (shift); the served slot is KERNAL-first (offset 0 = $E000, hardware-
        ; verified), so those are slot offsets $0B81 / $0BC2. Only 8 cells per
        ; table differ from US (the symbol cluster + 3 letter keys), so 16 single-
        ; byte SLOT_POKEs (see se_kbd_off / se_kbd_byte). SLOT_POKE targets a RAM
        ; slot, so this is RE-APPLIED every swap (not persistent across power-off
        ; -- RAM slots reload from flash at boot; that's why it lives here, not in
        ; cmd_font). If the plugin doesn't implement SLOT_POKE (carry set), bail
        ; and boot stock US -- never wedge the swap. (Display still needs the
        ; Swedish charset, which the served stock set lacks -- keyboard only.)
        lda KBD_LAYOUT
        cmp #1
        bne @no_se
        ldx #0
@se_loop:
        lda se_kbd_off,x
        sta rbcp_arg1                   ; offset lo
        lda #$0B
        sta rbcp_arg2                   ; offset mid (both tables in page $0B)
        lda #$00
        sta rbcp_arg3                   ; offset hi
        lda se_kbd_byte,x
        sta rbcp_arg0                   ; the Swedish cell value
        lda #RBCP_STOCK_RAM_SLOT
        sta rbcp_arg4                   ; target the loaded stock slot
        txa
        pha                             ; preserve the loop index (carry survives
        jsr rbcp_cmd_slot_poke          ;   pla/tax; only N/Z are touched)
        pla
        tax
        bcs @no_se                      ; SLOT_POKE unsupported -> US fallback
        inx
        cpx #16
        bne @se_loop
@no_se:

        lda #RBCP_STOCK_RAM_SLOT
        jsr rbcp_cmd_switch_and_exit    ; activate it; the device begins
                                        ; serving the new slot immediately
                                        ; (no polling per the protocol spec)
        TRACE_BORDER $06                ; blue: handoff -- lingers through the
                                        ; whole stock KERNAL/BASIC cold start

        ; Hand off through the stock-KERNAL reset vector. For a cart this lands
        ; in the CBM80 cold-start (stock reset's JMP ($8000)); with no cart it
        ; runs the full stock init and reaches READY. A loaded program in RAM
        ; survives the reset, so RUN from BASIC picks it up. (Going through
        ; (FFFC) -- rather than into a half-initialized environment -- is also
        ; what cleared the scattered $A0 artifacts seen on first hardware test.)
        ;
        ; NOTE: a RESTOR ($FF8A) call was tried here to fix the cart path's
        ; skipped RAM vectors and didn't help (the flakiness it targeted was
        ; later traced to a Meatloaf on the IEC bus -- see reset.s). It was
        ; dropped again: real carts boot with uninitialized vectors anyway, so
        ; they can't rely on them, and keeping the handoff a single JMP avoids
        ; executing stock ROM code before the game expects it.
        jmp ($FFFC)

; Swedish keyboard patch (used by the trampoline above). The 8 cells that differ
; from the US layout in each of the stock KERNAL's two decode tables -- the
; symbol cluster (+ - @ * : ; =) and the 3 letter keys (ae oe aring). se_kbd_off
; is the low byte of the slot offset (high bytes are $0B/$00 for all 16: $EB81+n
; unshift, $EBC2+n shift); se_kbd_byte is the PETSCII value to write. These match
; keytab_se / keytab_se_shift (irq.s) at matrix indices 40,43,45,46,48,49,50,53.
; In RBCP_CODE so they ride the copy-to-RAM with the trampoline; placed after the
; JMP so they're never executed. HARDWARE-VALIDATE the slot offsets ($EB81/$EBC2)
; and the resulting layout against a real Swedish keyboard.
se_kbd_off:
        .byte $A9,$AC,$AE,$AF,$B1,$B2,$B3,$B6   ; $EB81 (unshift) + {40,43,45,46,48,49,50,53}
        .byte $EA,$ED,$EF,$F0,$F2,$F3,$F4,$F7   ; $EBC2 (shift)   + same indices
se_kbd_byte:
        .byte $2D,$3D,$5C,$5B,$3A,$40,$5D,$3B   ; -  =  oe ae :  @  aring ;
        .byte $2D,$3D,$DC,$DB,$2A,$40,$DD,$2B   ; -  =  Oe Ae *  @  Aring +

; -------------------------------------------------------------------------
; rbcp_bootmenu_tramp - RAM-side trampoline for _rbcp_launch_bootmenu. Loads
; the bootloader (flash set 0) into a RAM slot the device isn't serving, switches
; to it, and resets through (FFFC) so the bootloader cold-boots and shows the
; menu. On any RBCP failure it does NOT switch (serving a half-copied slot =
; garbage) and just resets into the still-served shell -- so a non-One-ROM build
; simply reboots the shell, never wedges.
; -------------------------------------------------------------------------
rbcp_bootmenu_tramp:
        sei
        jsr rbcp_reset
        jsr rbcp_cmd_enter_cmd_resp
        bcs @bm_fail
        lda #RBCP_BOOTMENU_RAM_SLOT
        ldx #RBCP_BOOTMENU_FLASH_SLOT
        jsr rbcp_cmd_load_slot          ; flash set 0 -> RAM slot (long poll)
        bcs @bm_fail
        lda #RBCP_BOOTMENU_RAM_SLOT
        jsr rbcp_cmd_switch_and_exit    ; serve the bootloader now
@bm_fail:
        jmp ($FFFC)                     ; reset: bootloader cold-boots -> menu
                                        ; (or, on failure/no-One-ROM, the shell)

; The overlay library spans two 8KB flash sets (each holds whole overlays --
; no overlay straddles a set, so SLOT_PEEK only ever reads within one 8KB
; chip, which is the proven case). The C side puts the target set in the
; OVL_MB_SET mailbox before each fetch; loadable set indices are shell=0,
; stock=1, overlays-A=2, overlays-B=3 (cfg/onerom-stock.json order; plugins
; don't count).
OVL_MB_SET     = $02C3          ; flash set for this fetch (set by C caller)
OVL_RAM_SLOT   = 1              ; staging slot (shared with the stock swap)

; -------------------------------------------------------------------------
; rbcp_ovlm_tramp - RAM side of _overlay_fetch_multi: one session, looping
; SLOT_PEEK + copy per page. The destination store's hi byte is patched per
; page -- this code runs from RAM, so self-modification is fine.
; -------------------------------------------------------------------------
OVL_MB_PAGE = $02C0
OVL_MB_CNT  = $02C1
OVL_MB_DST  = $02C2

rbcp_ovlm_tramp:
        sei
        jsr rbcp_reset
        jsr rbcp_cmd_enter_cmd_resp
        bcs @enter_fail
        lda #OVL_RAM_SLOT
        ldx OVL_MB_SET
        jsr rbcp_cmd_load_slot
        bcs @load_fail
@page:
        lda #0
        sta rbcp_arg1           ; offset lo (pages are 256-aligned)
        sta rbcp_arg3           ; offset hi
        lda OVL_MB_PAGE
        sta rbcp_arg2           ; offset mid = page number
        lda #0                  ; count 0 = 256 bytes
        ldx #OVL_RAM_SLOT
        jsr rbcp_cmd_slot_peek
        bcs @peek_fail
        lda OVL_MB_DST
        sta @dst+2              ; patch the store's hi byte (RAM code)
        ldy #0
@cp:
        lda RBCP_DATA_ADDR,y
@dst:   sta $FF00,y             ; hi byte patched above
        iny
        bne @cp
        inc OVL_MB_PAGE
        inc OVL_MB_DST
        dec OVL_MB_CNT
        bne @page
        jsr rbcp_cmd_exit_cmd_resp
        bcs @exit_fail
        cli
        lda #0
        ldx #0
        rts
@enter_fail:
        cli
        lda #1
        ldx #0
        rts
@load_fail:
        jsr rbcp_cmd_exit_cmd_resp      ; best effort: leave CR mode
        cli
        lda #2
        ldx #0
        rts
@peek_fail:
        jsr rbcp_cmd_exit_cmd_resp
        cli
        lda #3
        ldx #0
        rts
@exit_fail:
        cli
        lda #4
        ldx #0
        rts

; =========================================================================
; NV (non-volatile) settings storage -- persist colors + history across a
; power cycle in the One ROM's NV flash (RBCP group $03). Same CR-mode + SEI
; + run-from-RAM discipline as the overlay fetch. Read/write parameters go in
; a small page-2 mailbox (RAM the library copy won't touch), set by the C
; caller before the call:
;   NV_MB_LEN ($02C4)     byte count (<= 255: fits one nv_peek / back-channel)
;   NV_MB_LO/HI ($02C5/6) address of the C-side blob buffer
;   NV_MB_IDX ($02C7)     write-loop index (scratch)
; The blob lives at NV offset 0.
; =========================================================================
NV_MB_LEN = $02C4
NV_MB_LO  = $02C5
NV_MB_HI  = $02C6
NV_MB_IDX = $02C7

; The settings blob lives at NV offset 16, not 0: the C= boot-menu bootloader
; (r107sl's c64-bootloader, flash set 0) stores its last-booted-slot byte at
; NV offset 1, which would land inside our "TD" magic. NV bytes 0-15 are the
; bootloader's; ours start here.
NV_BLOB_BASE = 16

; The C-callable entry points run in place from KERNAL ROM (like the overlay
; fetchers): each copies the library to RAM, then jumps into its RAM-side
; trampoline below. (The trampolines themselves must run from RAM.)
.segment "KCODE"

; _nv_capability - A = 1 if NV present AND writable, else 0. The C side caches
; this at boot; on a non-One-ROM (VICE / shell-only build) the RBCP handshake
; fails and it returns 0, so persistence stays inert.
.export _nv_capability
_nv_capability:
        jsr rbcp_copy_to_ram
        jmp rbcp_nv_cap_tramp

; _nv_read - read NV_MB_LEN bytes from NV offset 0 into the blob at NV_MB_LO/HI.
.export _nv_read
_nv_read:
        jsr rbcp_copy_to_ram
        jmp rbcp_nv_read_tramp

; _nv_write - write NV_MB_LEN blob bytes to NV offset 0 (BEGIN / POKE xN / COMMIT).
.export _nv_write
_nv_write:
        jsr rbcp_copy_to_ram
        jmp rbcp_nv_write_tramp

; --- RAM-side NV trampolines (run from RBCP_RAM after the copy) --------------
.segment "RBCP_CODE"

rbcp_nv_cap_tramp:
        sei
        jsr rbcp_reset
        jsr rbcp_cmd_enter_cmd_resp
        bcs @cap_enter_fail
        jsr rbcp_cmd_get_nv_capability
        bcs @cap_reject
        lda RBCP_DATA_ADDR + RBCP_NV_CAP_SIZE_LO
        ora RBCP_DATA_ADDR + RBCP_NV_CAP_SIZE_HI
        beq @cap_reject                 ; size 0 -> no NV present
        lda RBCP_DATA_ADDR + RBCP_NV_CAP_WRITABLE
        beq @cap_reject                 ; present but read-only
        jsr rbcp_cmd_exit_cmd_resp
        cli
        lda #1
        ldx #0
        rts
@cap_reject:
        jsr rbcp_cmd_exit_cmd_resp
@cap_enter_fail:
        cli
        lda #0
        ldx #0
        rts

rbcp_nv_read_tramp:
        sei
        jsr rbcp_reset
        jsr rbcp_cmd_enter_cmd_resp
        bcs @rd_enter_fail
        lda NV_MB_LEN
        sta rbcp_arg0                   ; count
        lda #NV_BLOB_BASE
        sta rbcp_arg1                   ; loc lo = blob base
        lda #0
        sta rbcp_arg2                   ; loc hi = 0
        jsr rbcp_cmd_nv_peek
        bcs @rd_peek_fail
        lda NV_MB_LO                    ; back-channel -> blob, LEN bytes
        sta copy_dst
        lda NV_MB_HI
        sta copy_dst+1
        ldy #0
@rd_cp:
        cpy NV_MB_LEN
        beq @rd_done
        lda RBCP_DATA_ADDR,y
        sta (copy_dst),y
        iny
        bne @rd_cp
@rd_done:
        jsr rbcp_cmd_exit_cmd_resp
        bcs @rd_exit_fail
        cli
        lda #0
        ldx #0
        rts
@rd_enter_fail:
        cli
        lda #1
        ldx #0
        rts
@rd_peek_fail:
        jsr rbcp_cmd_exit_cmd_resp
        cli
        lda #3
        ldx #0
        rts
@rd_exit_fail:
        cli
        lda #4
        ldx #0
        rts

rbcp_nv_write_tramp:
        sei
        jsr rbcp_reset
        jsr rbcp_cmd_enter_cmd_resp
        bcs @wr_enter_fail
        lda #OVL_RAM_SLOT               ; stage in RAM slot 1
        sta rbcp_arg0
        jsr rbcp_cmd_nv_poke_begin
        bcs @wr_begin_fail
        lda NV_MB_LO                    ; copy_dst = blob (survives pokes: $AD)
        sta copy_dst
        lda NV_MB_HI
        sta copy_dst+1
        lda #0
        sta NV_MB_IDX
@wr_pk:
        lda NV_MB_IDX
        cmp NV_MB_LEN
        beq @wr_commit
        tay
        lda (copy_dst),y                ; blob[idx]
        sta rbcp_arg0                   ; byte value
        lda NV_MB_IDX
        clc
        adc #NV_BLOB_BASE
        sta rbcp_arg1                   ; loc lo = blob base + idx
        lda #0
        sta rbcp_arg2                   ; loc hi = 0 (base+len stays < 256)
        jsr rbcp_cmd_nv_poke
        bcs @wr_poke_fail
        inc NV_MB_IDX
        jmp @wr_pk
@wr_commit:
        jsr rbcp_cmd_nv_poke_commit     ; flush to flash (long poll)
        bcs @wr_poke_fail
        jsr rbcp_cmd_exit_cmd_resp
        bcs @wr_exit_fail
        cli
        lda #0
        ldx #0
        rts
@wr_poke_fail:                          ; poke or commit failed: drop staging
        jsr rbcp_cmd_nv_poke_discard
        jsr rbcp_cmd_exit_cmd_resp
        cli
        lda #3
        ldx #0
        rts
@wr_begin_fail:
        jsr rbcp_cmd_exit_cmd_resp
        cli
        lda #2
        ldx #0
        rts
@wr_enter_fail:
        cli
        lda #1
        ldx #0
        rts
@wr_exit_fail:
        cli
        lda #4
        ldx #0
        rts

; =========================================================================
; Font (character-ROM) switch -- live SWITCH_SLOT between two served sets that
; carry identical KERNAL/BASIC + a different char ROM (so the CPU never
; notices; only the font the VIC reads changes). Same CR-mode + SEI +
; run-from-RAM discipline as the overlay/NV trampolines. Params in a page-2
; mailbox (set by the C caller):
;   FONT_MB_LOAD ($02C8)  1 = LOAD_SLOT the set into RAM first, 0 = SWITCH only
;   FONT_MB_FLASH ($02C9) flash (loadable ROM) set to LOAD (when LOAD=1)
;   FONT_MB_RAM  ($02CA)  RAM slot to load-into / switch-to
; The caller must NOT LOAD into the currently-served slot (it would rewrite the
; live KERNAL/BASIC mid-fetch and crash), so it tracks the current font and
; only LOADs the alternate slot. Hardware-only (inert without a One ROM).
; =========================================================================
FONT_MB_LOAD  = $02C8
FONT_MB_FLASH = $02C9
FONT_MB_RAM   = $02CA

.segment "KCODE"
.export _font_apply
_font_apply:
        jsr rbcp_copy_to_ram
        jmp rbcp_font_tramp

; -------------------------------------------------------------------------
; Bank dispatch -- ROM-expansion PoC (docs/ROM-EXPANSION.md, Option A).
;
; _bank_run_test: swap the served BASIC window ($A000-$BFFF) to the test bank
; (loadable ROM set BANK_FLASH_SET, staged into RAM slot BANK_RAM_SLOT), JSR its
; $A000 JMP-table entry 0, then switch back to the base set in RAM slot 0. The
; bank set carries a byte-IDENTICAL KERNAL + char to the base, so SWITCH_SLOT is
; live-safe -- the CPU runs from the unchanging KERNAL half throughout, exactly
; like the font swap. This routine LIVES in KCODE (that static KERNAL half), so
; it survives both swaps, and it reuses _font_apply's LOAD_SLOT+SWITCH_SLOT via
; the FONT_MB mailbox.
;
; BANK_RAM_SLOT is the overlay/stock scratch slot (1), which is NEVER the served
; slot, so overwriting it is always safe (an overlay just reloads on next use).
; The bank must not touch the RBCP RAM block ($C800-$CDFF) or the swap-back
; breaks. Returns A=0 if the bank ran, nonzero if the swap-in failed (no One ROM
; / RBCP error) -- in which case we must NOT JSR $A000, since that's the base's
; own BASIC-half code, not the bank. Hardware-only (inert without a One ROM).
; -------------------------------------------------------------------------
BANK_FLASH_SET = 8              ; loadable ROM set: [kernal | char | bank1]
BANK_RAM_SLOT  = 1              ; overlay/stock scratch slot (never served)
BANK_ENTRY     = $A000          ; the bank's JMP-table entry 0

.export _bank_run_test
_bank_run_test:
        lda #1
        sta FONT_MB_LOAD        ; LOAD the bank set, then SWITCH to it
        lda #BANK_FLASH_SET
        sta FONT_MB_FLASH
        lda #BANK_RAM_SLOT
        sta FONT_MB_RAM
        jsr _font_apply
        cmp #0
        bne @done               ; swap-in failed: A nonzero, do NOT call $A000
        jsr BANK_ENTRY          ; run the bank command from ROM (base swapped out)
        lda #0
        sta FONT_MB_LOAD        ; SWITCH-only back to the base slot 0
        sta FONT_MB_RAM
        jsr _font_apply
        lda #0                  ; ran the bank -> success
@done:  ldx #0
        rts

.segment "RBCP_CODE"
rbcp_font_tramp:
        sei
        jsr rbcp_reset
        jsr rbcp_cmd_enter_cmd_resp
        bcs @ft_enter_fail
        lda FONT_MB_LOAD
        beq @ft_switch                  ; SWITCH only (slot already loaded)
        lda FONT_MB_RAM                 ; LOAD_SLOT: A = RAM slot, X = flash slot
        ldx FONT_MB_FLASH
        jsr rbcp_cmd_load_slot
        bcs @ft_fail
@ft_switch:
        lda FONT_MB_RAM
        jsr rbcp_cmd_switch_slot        ; live activate (CPU keeps running)
        bcs @ft_fail
        jsr rbcp_cmd_exit_cmd_resp
        bcs @ft_exit_fail
        cli
        lda #0
        ldx #0
        rts
@ft_fail:
        jsr rbcp_cmd_exit_cmd_resp      ; best effort: leave CR mode
        cli
        lda #3
        ldx #0
        rts
@ft_enter_fail:
        cli
        lda #1
        ldx #0
        rts
@ft_exit_fail:
        cli
        lda #4
        ldx #0
        rts

; =========================================================================
; RUN/STOP+RESTORE escape from a launched stock program.
;
; After `run` swaps to the stock ROMs, run_stub (c_io.s) points the stock NMI
; vector ($0318) at rbcp_nmi_escape below. RESTORE is wired to the NMI line, so
; pressing it runs this handler; if RUN/STOP is held too we swap the One ROM
; back to the shell ROM set and reboot into the shell. RESTORE alone chains to
; the stock NMI continuation, so it behaves normally.
;
; The shell ROM set is still in RAM slot 0 -- the launch only overwrote RAM
; slot 1 (RBCP_STOCK_RAM_SLOT / OVL_RAM_SLOT) -- so a SWITCH_SLOT back to slot 0
; restores it. (If font B was active, slot 0 holds font A; the shell reboots in
; font A and settings_load re-applies font B, the same as the font/reset edge.)
;
; This block lives in RBCP_CODE, so it's already copied to $C8xx RAM before the
; swap and survives it. Best-effort: a program that revectors $0318, masks the
; CIA2 NMI source, or overwrites this RAM defeats it. Hardware-only -- without a
; One ROM there's no slot to switch, and enter_cmd_resp just fails through to a
; plain reboot.
; =========================================================================
RBCP_SHELL_RAM_SLOT = 0         ; boot-served slot; still holds the shell ROMs
STOCK_NMI_CONT      = $FE47     ; stock KERNAL NMI continuation (default $0318)

.segment "RBCP_CODE"
.export rbcp_nmi_escape
.export rbcp_escape_tramp                ; exported for the VICE clear-CBM80 test

rbcp_nmi_escape:
        pha                             ; we clobber A reading the key matrix
        lda #$7F
        sta $DC00                       ; CIA1 PRA: select keyboard column 7
        lda $DC01                       ; CIA1 PRB: read rows; RUN/STOP = row 7
        and #$80
        bne @pass                       ; bit set = STOP up -> bare RESTORE
        jmp rbcp_escape_tramp           ; RUN/STOP+RESTORE -> back to the shell
@pass:
        pla                             ; restore A; the stock handler saves the
        jmp STOCK_NMI_CONT              ; regs itself, so chain with a clean stack

rbcp_escape_tramp:
        sei
        ; `run` planted a CBM80 autostart signature at $8000 (so the stock reset
        ; would launch the program). We're rebooting into the SHELL, whose reset
        ; runs the same cartridge-autostart check ($8004-$8008 = $C3,$C2,$CD,$38,
        ; $30, reset.s) -- it would find the still-planted signature and relaunch
        ; the very program we're escaping from. Invalidate it first.
        lda #0
        sta $8004
        jsr rbcp_reset
        jsr rbcp_cmd_enter_cmd_resp
        bcs @reboot                     ; no device / comms broken: reboot anyway
        lda #RBCP_SHELL_RAM_SLOT
        jsr rbcp_cmd_switch_slot        ; serve the shell ROM set again
        jsr rbcp_cmd_exit_cmd_resp
@reboot:
        jmp ($FFFC)                     ; now the shell's reset vector
