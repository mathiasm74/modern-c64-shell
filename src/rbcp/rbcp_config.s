; rbcp_config.s -- RBCP library configuration for our shell ROM.
;
; The shell's KERNAL ROM is at $E000-$FFFF; we map the command page and the
; back-channel region into the $EDxx-$EFxx fill region near the top, well
; away from the hot code path. While the device is in command-response mode,
; reads from those addresses are commands/responses; outside CR mode, the
; plugin still *watches* those addresses for the knock sequence, which is
; why we keep them out of our active instruction-fetch range.
;
; All of this only matters when the host-control plugin is active on the One
; ROM device. In VICE (no plugin model), these reads are inert.

; --- Where the ROM lives ---------------------------------------------------
CONFIG_ROM_BASE_HI = $E0                ; KERNAL ROM at $E000
CONFIG_ROM_SIZE    = $2000              ; 8KB

; --- Command page (must be away from our hot code paths) -------------------
; The c64-boot reference uses $E0, but for *us* that's the worst possible
; choice: our reset.s code lives at $E000-$E25E, so the CPU is constantly
; fetching instructions through whichever page is the command page. The
; host-control plugin watches every read at the command page (it has to, to
; detect the !RBCP! knock that *enters* CR mode); even with a transparent
; passthrough, that watch added enough fragility to our boot that small
; code-layout shifts could push it from "noisy banner" to "black screen"
; on real hardware.
;
; Move command page and back-channel into the $EDxx-$EFxx fill region of
; KERNAL ROM. Our actual code ends around $EC00; everything past is $FF
; until the pinned legacy stubs at $FCxx, so the plugin can watch as much
; as it wants without poking our hot path.
CONFIG_RBCP_CMD_PAGE     = $EE
CONFIG_RBCP_CMD_PAGE_REL = CONFIG_RBCP_CMD_PAGE - CONFIG_ROM_BASE_HI

; --- Back-channel region ($EF00..$F0FF) -----------------------------------
; 512 bytes including the 8-byte response header and 504 bytes of response
; data. Lives at $EF00-$F0FF, immediately above the $EE command page in the
; KERNAL ROM fill region. Pinned legacy stubs don't start until $FC85 so
; there's headroom; we just need to stay clear of CODE2 (which currently
; ends around $ED60 with cmd_runstock).
CONFIG_RBCP_BCH_BASE  = $EF00
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
