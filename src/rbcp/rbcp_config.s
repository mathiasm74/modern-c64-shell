; rbcp_config.s -- RBCP library configuration for our shell ROM.
;
; The shell's KERNAL ROM is at $E000-$FFFF. The COMMAND PAGE is where the host
; reads to issue commands and the plugin watches for the !RBCP! knock; the
; BACK-CHANNEL is where the device writes its responses for the host to read.
;
; All of this only matters when the host-control plugin is active on the One
; ROM device. In VICE (no plugin model), these reads are inert.

; --- Where the ROM lives ---------------------------------------------------
; TARGET_C128: on the Commodore 128, Tardis is the C64-mode ROM in socket U32 --
; a single 16KB image [BASIC $A000 | KERNAL $E000], the two 8KB halves served to
; two NON-contiguous CPU windows. The One ROM plugin serves the whole 16KB and
; watches image offset 0 (= $A000, the BASIC half) for the command-page knock by
; default. So on the C128 the command page must be $A0 (image offset 0), NOT $E0
; (which is image offset $2000 -- the plugin would never hear the knock there).
; The back-channel can still sit at $FE00 (KERNAL half), but its ROM-relative
; offset is $3E00 (KERNAL is the 2nd 8KB of the image), which the linear formula
; below (built for a contiguous ROM) can't derive -- so it's set explicitly.
.ifdef TARGET_C128
CONFIG_ROM_BASE_HI = $A0                ; image offset 0 = $A000 (BASIC half)
CONFIG_ROM_SIZE    = $4000              ; 16KB (the whole U32 image)
.else
CONFIG_ROM_BASE_HI = $E0                ; KERNAL ROM at $E000
CONFIG_ROM_SIZE    = $2000              ; 8KB
.endif

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
.ifdef TARGET_C128
CONFIG_RBCP_CMD_PAGE     = $A0          ; knock at $A000 (image offset 0 = rel-0)
.else
CONFIG_RBCP_CMD_PAGE     = $E0
.endif
CONFIG_RBCP_CMD_PAGE_REL = CONFIG_RBCP_CMD_PAGE - CONFIG_ROM_BASE_HI

; --- Back-channel region ($FE00..$FF0F) ------------------------------------
; Where the device writes responses (8-byte header + data). Unlike the command
; page, the host TELLS the device this location during the enter-CR handshake,
; so it can sit wherever is convenient -- but it MUST be ROM the device may
; freely overwrite: the writes mutate the served image (persistently, until a
; reflash), so any code under the window is corrupted by the first session.
; That bug shipped once: the window sat at $FA00 in the big fill run below
; the stubs, code silently grew past $FA00, and every overlay fetch sprayed
; back-channel bytes over live shell code (the v0.12 "about" corruption).
;
; $FE00 is structurally safe: it sits in the gap between the pinned legacy-
; stub segments ($FDA4-$FF5D), which is not on any linker flow path -- code
; that grows collides with a pinned stub segment and FAILS THE BUILD long
; before it could reach this window. test_rbcp.py also asserts the window
; region is $FF fill in the built image.
;
; 272 bytes = 8-byte header + 264 data: SLOT_PEEK moves at most 256 bytes per
; command and needs data_size >= count, so this is the smallest comfortable
; window. The $FF fill is also safe for the progress/status header bytes
; (offsets +$04/+$05), which must not equal $BB/$CC or their inverses $44/$33.
CONFIG_RBCP_BCH_BASE  = $FE00
.ifdef TARGET_C128
; $FE00 is image offset $3E00 (KERNAL is the 2nd 8KB of the 16KB image), not the
; $5E00 the contiguous-ROM formula would give from base $A000.
CONFIG_RBCP_BCH_START = $3E00
.else
CONFIG_RBCP_BCH_START = (CONFIG_RBCP_BCH_BASE - (CONFIG_ROM_BASE_HI * $100))
.endif
CONFIG_RBCP_BCH_SIZE  = 272

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
