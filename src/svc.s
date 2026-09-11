; svc.s - shell-services jump table at a fixed address ($FF80).
;
; Overlays are linked standalone and can't see resident symbols, so the few
; resident routines an overlay needs are reached through this fixed table --
; the same idea as the KERNAL jump table, but for our own services. The dir
; overlay (src/overlays/dir.c) uses it for the IEC bus and the Epyx fast
; receiver so it can list directories (standard and fast) without bundling
; that code itself.
;
; The entries' addresses ARE the ABI: src/overlays/svc.h hardcodes them. Keep
; this order and the start address ($FF80) in sync with svc.h, and don't let
; CODE2 grow past $FF80 (cfg/rom.cfg pins this segment there). 16 entries,
; $FF80-$FFAF, sitting in the KERNAL ROM gap below the $FFBA file-I/O stubs.
;
; CONSTRAINT: an svc routine may take AT MOST ONE argument. An overlay and the
; resident shell run on SEPARATE cc65 C stacks (overlay sp in ZP $40-$5F,
; resident sp in $02-$1F), so the LAST argument -- passed in registers -- crosses
; fine, but an earlier STACK-passed argument lands on the wrong stack as garbage.
; For a multi-value call, add a resident 0/1-arg wrapper (svc 12 is exactly that:
; the "$" variant of the 2-arg send_header, which corrupted its name otherwise).

.import _iec_set_fa, _iec_set_sa, _iec_setname, _iec_open, _iec_status
.import _iec_chkin, _iec_getbyte, _iec_close, _iec_clrchn
.import _iec_set_fnadr, _iec_set_fnlen, _iec_command_raw
.import _fastload_set_device, _fastload_epyx_capable, _fastload_epyx_install
.import _fastload_epyx_send_dir_header, _fastload_epyx_mark_unsupported
.import _epyx_wait_ready, _epyx_recv_byte

.segment "SVC_TABLE"

        jmp _iec_set_fa                     ; $FF80  svc 0
        jmp _iec_set_sa                     ; $FF83  svc 1
        jmp _iec_setname                    ; $FF86  svc 2
        jmp _iec_open                       ; $FF89  svc 3
        jmp _iec_status                     ; $FF8C  svc 4
        jmp _iec_chkin                      ; $FF8F  svc 5
        jmp _iec_getbyte                    ; $FF92  svc 6
        jmp _iec_close                      ; $FF95  svc 7
        jmp _iec_clrchn                     ; $FF98  svc 8
        jmp _fastload_set_device            ; $FF9B  svc 9
        jmp _fastload_epyx_capable          ; $FF9E  svc 10
        jmp _fastload_epyx_install          ; $FFA1  svc 11
        jmp _fastload_epyx_send_dir_header  ; $FFA4  svc 12 (0-arg "$"; see note)
        jmp _fastload_epyx_mark_unsupported ; $FFA7  svc 13
        jmp _epyx_wait_ready                ; $FFAA  svc 14
        jmp _epyx_recv_byte                 ; $FFAD  svc 15
        ; --- added for the DISK BANK (docs/ROM-EXPANSION.md) ---------------
        ; fastload.c moved into the bank and needs these three IEC primitives,
        ; which stay resident (the whole shell uses them). Appended rather than
        ; slotted in so svc 0-15 keep their published addresses; svc 9-15 above
        ; become dead once the bank owns the Epyx path (stage 4 removes them and
        ; these three move down into the freed slots).
        jmp _iec_set_fnadr                  ; $FFB0  svc 16
        jmp _iec_set_fnlen                  ; $FFB3  svc 17
        jmp _iec_command_raw                ; $FFB6  svc 18  (table ends $FFB8)
