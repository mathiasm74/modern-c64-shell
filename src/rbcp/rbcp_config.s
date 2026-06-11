; rbcp_config.s -- RBCP library configuration for our shell ROM.
;
; The shell's KERNAL ROM is at $E000-$FFFF. The COMMAND PAGE is where the host
; reads to issue commands and the plugin watches for the !RBCP! knock; the
; BACK-CHANNEL is where the device writes its responses for the host to read.
;
; All of this only matters when the host-control plugin is active on the One
; ROM device. In VICE (no plugin model), these reads are inert.

; --- Where the ROM lives ---------------------------------------------------
CONFIG_ROM_BASE_HI = $E0                ; KERNAL ROM at $E000
CONFIG_ROM_SIZE    = $2000              ; 8KB

; --- Command page ----------------------------------------------------------
; Must be the page the plugin watches at power-on, or the very first knock is
; never heard. The host-control plugin's command_page DEFAULTS to ROM-relative
; page 0 (= $E000) and only moves once the host configures it -- and it can't
; configure without first being heard. So the knock MUST land on rel-0: command
; page = $E0.
;
; A previous version used $EE to keep the watched page off our $E000 reset code,
; but that broke the swap entirely: we knocked at a page the plugin was not
; watching. The plugin's watch of $E000 is a passive passthrough until the knock
; sequence appears, so our normal boot (which fetches instructions through
; $E000) is unaffected -- and is in fact already running with the plugin
; watching rel-0 by default.
CONFIG_RBCP_CMD_PAGE     = $E0
CONFIG_RBCP_CMD_PAGE_REL = CONFIG_RBCP_CMD_PAGE - CONFIG_ROM_BASE_HI

; --- Back-channel region ($FA00..$FBFF) ------------------------------------
; Where the device writes responses (8-byte header + 504 bytes of data). Unlike
; the command page, the host TELLS the device this location during the enter-CR
; handshake, so it can sit wherever is convenient. We put it high in the KERNAL
; ROM's free fill run (currently $F5DF-$FC84, just below the pinned legacy stubs
; at $FC85) -- all $FF, clear of our code. The $FF fill is also safe for the
; progress/status header bytes (offsets +$04/+$05), which must not equal $BB/$CC
; or their inverses $44/$33. (TODO: pin this with a reserved linker segment so
; growing code can't reach it once the swap is validated.)
CONFIG_RBCP_BCH_BASE  = $FA00
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
