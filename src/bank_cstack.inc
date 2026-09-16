; bank_cstack.inc - the served bank's C-stack top, which is also the top of its
; RAM window. Included by every crt0_*.s so the two targets cannot drift.
;
; One ROM: the bank is served at $A000-$BFFF and $8000-$9FFF underneath it is
; plain RAM, so the window sits just below the bank at $9D00-$9FFF.
;
; EasyFlash: it cannot. ROML occupies $8000-$9FFF, so a write there lands in
; the RAM underneath but the read comes back from flash -- the window would be
; write-only, and every C bank entry would run its init and then quietly do
; nothing. It moves to $C800-$CDFF, between the shell's C stack and the $CE00
; completion cache (src/ef/platform.s carries the full map of that page).
.ifdef EF_BANK
CSTACK_TOP = $CE00
.else
CSTACK_TOP = $A000
.endif
