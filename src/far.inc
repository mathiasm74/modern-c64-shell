; far.inc - the cross-bank call (far_call) cells, shared by both targets.
;
; far_call (src/rbcp/launch.s; the EasyFlash twin is in src/ef/platform.s) lets
; a RUNNING BANK call a SERVICE ENTRY in another bank and get back to itself,
; not to the base. It is reached through SVC 13 ($FFA7 / EF $9FA7):
;
;     ldy #(bank << 5) | entry      ; the target, BANK_CMD packing
;     lda #<arg / ldx #>arg         ; ONE 16-bit argument, usually a pointer
;     jsr far_svc                   ; A/X = the service's 16-bit result
;
; The result is $FFFF when the call could not be made (no such bank, or a call
; from inside a service), so services must never return $FFFF themselves.
;
; A service entry is a plain cc65 function that does NOT run bank_init: it
; keeps using the caller's C stack (every bank's cc65 zero page is the same 26
; bytes at $40, so `sp` is the same cell in both) and must own no BSS, DATA or
; zero page of its own -- that RAM belongs to the caller while the call lasts.
;
; These cells are in the tape buffer, clear of the $0370-$03A6 mailboxes. Page 3
; is power-on garbage, so bank_call clears FAR_DEPTH on every command: a far
; call only ever happens inside one.
FAR_DEPTH  = $03A7              ; 1 while a far call is in progress
FAR_ARG    = $03A8              ; 2: the argument in, the result out
FAR_CALLER = $03AA              ; bank id of the caller, re-served on return
FAR_VEC    = $03AB              ; 2: EasyFlash's entry vector (One ROM: BANK_VEC)

; VICE only (no One ROM): the callee's image waits in the RAM under the KERNAL
; ($E000) and is exchanged with the caller's at $A000 for the call. The exchange
; loop cannot run from either half it swaps, so it is copied here first.
XCHG_RUN   = $03B0              ; up to $03FB
FAR_SHADOW = $E000
