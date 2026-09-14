; ============================================================================
; kload.s -- code patched INTO the served stock KERNAL, in its tape space.
;
; This does NOT run in our environment. It is stored in our KERNAL ROM as data,
; SLOT_POKEd into the stock KERNAL image before the One ROM switches to it, and
; then runs at $F8E2 under the STOCK ROMs with our ROM gone. So it may call the
; stock KERNAL freely ($FFxx and the internal entries below) and may call nothing
; of ours.
;
; WHY HERE. After `run`, a program that keeps loading -- levels, multi-load
; titles -- gets stock-speed loads, because nothing wedges LOAD. A real Epyx
; cartridge stays resident and does, which is why it can be far faster on the
; same drive. Putting the wedge in ROM rather than planting it in RAM is what
; makes it survive: a RAM wedge at $C000 dies to RESTOR, to RUN/STOP+RESTORE and
; to any program that uses that memory.
;
; WHY THE TAPE SPACE. Tape is an explicit non-goal for this shell, and
; docs/TAPE-SPACE.md establishes that $F8E2-$FB8D (684 bytes) is reachable only
; from the tape paths -- no other code reaches it and nothing outside references
; into it. Regenerate that analysis with tools/kernal_map.py.
;
; HOW IT IS HOOKED. Not by patching LOAD's code, but by repointing the ROM's own
; vector table: the ILOAD entry at $FD4C (slot offset $1D4C) is what RESTOR
; copies into $0330. Patching the TABLE means the hook survives any later RESTOR
; the program does -- patching $0330 itself would not.
;
; STAGE 1 (this file today): the dispatch and the fallback only, with a visible
; marker. It ticks the border and hands straight to the stock serial loader, so
; every LOAD still works exactly as before while proving that ~20 bytes reached
; the served ROM and that the repointed vector calls them. The Epyx receiver
; goes in next, in the same space, behind the same dispatch.
; ============================================================================

KLOAD_ORG = $F8E2               ; start of the tape-only run (docs/TAPE-SPACE.md)

; --- stock KERNAL locations this code uses ---------------------------------
ST       = $90                  ; I/O status
FA       = $BA                  ; current device
VERCK    = $93                  ; load/verify flag
VIC_BORDER = $D020

STOCK_SERIAL = $F4B8            ; LOAD's serial path, entered past its device
                                ; dispatch: it re-reads FA itself and only needs
                                ; VERCK and ST set, which we do below.
STOCK_ILLEGAL = $F713           ; "illegal device number"

        .segment "KLOAD"

; ILOAD replacement. Entry conditions are exactly the stock entry's ($F4A5):
; A = 0 load / 1 verify, and $F49E has already stashed X/Y (the load-address
; override) into $C3/$C4 before its JMP ($0330).
kload_entry:
        sta VERCK
        lda #$00
        sta ST
        lda FA
        beq @illegal                    ; 0 = keyboard
        cmp #$03
        beq @illegal                    ; 3 = screen
        bcc @illegal                    ; 1,2 = tape / RS-232. Tape is what this
                                        ; code replaced, so it cannot be offered
                                        ; -- and it is a non-goal anyway.
        ; --- device 4+: the serial path -------------------------------------
        ; Stage 1 marker: tick the border so a LOAD visibly proves this code ran
        ; from the patched ROM. Replaced by the Epyx attempt, which will fall
        ; through to the same stock loader whenever it cannot or should not run
        ; (not an Epyx-capable drive, a bad upload, a verify) -- that fallback is
        ; what makes the whole patch safe.
        inc VIC_BORDER
        jmp STOCK_SERIAL

@illegal:
        jmp STOCK_ILLEGAL

kload_end:
        .export kload_entry, kload_end
