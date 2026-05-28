; rbcp_config.s -- RBCP library configuration for our shell ROM.
;
; The shell's KERNAL ROM is at $E000-$FFFF; we map the command page and the
; back-channel region into the first 768 bytes of it. While the device is in
; command-response mode, reads from those addresses are commands/responses;
; outside CR mode, the same addresses return whatever ROM bytes we placed
; there. Our reset.s code lives in the first few hundred bytes of KERNAL, so
; we keep the command page at $E0xx but route the back-channel further down
; the address space to a region we don't actively read while in CR mode.
;
; All of this only matters when the host-control plugin is active on the One
; ROM device. In VICE (no plugin model), these reads are inert.

; --- Where the ROM lives ---------------------------------------------------
CONFIG_ROM_BASE_HI = $E0                ; KERNAL ROM at $E000
CONFIG_ROM_SIZE    = $2000              ; 8KB

; --- Command page (matches the reference's default) ------------------------
CONFIG_RBCP_CMD_PAGE     = $E0          ; $E0xx reads = command bytes (in CR mode)
CONFIG_RBCP_CMD_PAGE_REL = CONFIG_RBCP_CMD_PAGE - CONFIG_ROM_BASE_HI

; --- Back-channel region ($E100..$E2FF) -----------------------------------
; 512 bytes including the 8-byte response header and 504 bytes of response
; data. Lives inside our KERNAL ROM at $E100-$E2FF. While the device is in
; CR mode, the One ROM serves dynamic response bytes here. Outside CR mode
; those addresses return whatever ROM bytes we put there -- our reset.s
; banner code is later than $E2FF, so nothing critical sits in this window.
CONFIG_RBCP_BCH_BASE  = $E100
CONFIG_RBCP_BCH_START = (CONFIG_RBCP_BCH_BASE - (CONFIG_ROM_BASE_HI * $100))
CONFIG_RBCP_BCH_SIZE  = 512

; --- Sentinel values for progress / status -------------------------------
; Both these and their bitwise inverses must not appear in the ROM image at
; the back-channel header offsets +$04 / +$05 -- the library uses inverse
; detection to spot device updates. The reference's $BB / $CC are safe;
; their inverses ($44 / $33) are also unlikely opcodes/data at those offsets.
CONFIG_RBCP_COMPLETE  = $BB
CONFIG_RBCP_STATUS_OK = $CC

; --- Timeouts and retries -------------------------------------------------
CONFIG_RBCP_POLL_TIMEOUT    = $FF
CONFIG_RBCP_NV_POLL_TIMEOUT = $FFFF
CONFIG_RBCP_TIMEOUT_RETRIES = $03
CONFIG_RBCP_CMD_PAUSE       = $10       ; spin count between non-CR commands

; --- Zero-page block ------------------------------------------------------
; The library wants 16 bytes of contiguous zero page. $80-$8F is the cleanest
; gap in our zp map (the cc65 pseudo-regs occupy $02-$1B, the iec.s and
; KERNAL-standard variables sit at $90+). $80-$8F is unclaimed.
CONFIG_RBCP_ZP_BASE   = $80
CONFIG_RBCP_ZP_LENGTH = 16
