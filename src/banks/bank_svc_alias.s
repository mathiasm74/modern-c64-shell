; bank_svc_alias.s - resolve the overlay's svc_* Epyx names to the DISK BANK's
; own local copies.
;
; src/overlays/dir.c is built BOTH as the RAM overlay and into the bank, from one
; source. In the overlay those Epyx calls go through the SVC table at $FF80 (the
; cfg SYMBOLS block pins each svc_* to its slot); in the bank the very same code
; lives a few hundred bytes away in the same image, so the calls should land
; there directly instead of bouncing through a resident jump table -- which is
; also the only correct answer once the resident copy is deleted in stage 4.
;
; These are pure symbol ALIASES, not jmp thunks: they cost zero bytes and turn
; each call into a direct jsr to the local routine, which matters because the
; Epyx receive path is cycle-counted.
;
; The iec_* services are NOT aliased here -- those genuinely stay resident (they
; are shared with the rest of the shell) and are bound to their fixed SVC
; addresses by the SYMBOLS block in cfg/disk_bank.cfg.

.import _fastload_set_device, _fastload_epyx_capable, _fastload_epyx_install
.import _fastload_epyx_send_dir_header, _fastload_epyx_mark_unsupported
.import _epyx_wait_ready, _epyx_recv_byte

.export _svc_fastload_set_device           := _fastload_set_device
.export _svc_fastload_epyx_capable         := _fastload_epyx_capable
.export _svc_fastload_epyx_install         := _fastload_epyx_install
.export _svc_fastload_epyx_send_dir_header := _fastload_epyx_send_dir_header
.export _svc_fastload_epyx_mark_unsupported := _fastload_epyx_mark_unsupported
.export _svc_epyx_wait_ready               := _epyx_wait_ready
.export _svc_epyx_recv_byte                := _epyx_recv_byte
