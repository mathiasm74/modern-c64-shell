; svc.s - shell-services jump table at a fixed address ($FF80).
;
; The DISK BANK (src/banks/) is linked standalone and can't see resident
; symbols, so the resident routines it needs are reached through this fixed
; table -- the same idea as the KERNAL jump table, but for our own services.
; While a bank runs, this ROM's BASIC half is swapped out entirely, which makes
; the table (in the static KERNAL half) the only resident code it can call
; besides the KERNAL stubs. cfg/disk_bank.cfg pins these addresses.
;
; The entries' addresses ARE the ABI: src/overlays/svc.h hardcodes them. Keep
; this order and the start address ($FF80) in sync with the cfg, and don't let
; CODE2 grow past $FF80 (cfg/rom.cfg pins this segment there). 12 entries,
; $FF80-$FFA3, sitting in the KERNAL ROM gap below the $FFBA file-I/O stubs.
;
; CONSTRAINT: an svc routine may take AT MOST ONE argument. The bank and the
; resident shell run on SEPARATE cc65 C stacks (bank sp in ZP $40-$5F, resident
; sp in $02-$1F), so the LAST argument -- passed in registers -- crosses fine,
; but an earlier STACK-passed argument lands on the wrong stack as garbage. A
; multi-value call needs a resident 0/1-arg wrapper. (This is why the surviving
; entries are all 0- or 1-arg primitives.)

.import _iec_set_fa, _iec_set_sa, _iec_setname, _iec_open, _iec_status
.import _iec_chkin, _iec_getbyte, _iec_close, _iec_clrchn
.import _iec_set_fnadr, _iec_set_fnlen, _iec_command_raw

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
        ; svc 9-11 were the Epyx fast-loader services. They went away when the
        ; disk cluster moved into the DISK BANK (docs/ROM-EXPANSION.md): the
        ; bank carries its own copy of that protocol and calls it directly, both
        ; because nothing resident uses it any more and because the receive path
        ; is cycle-counted and should not bounce through a jump table. The three
        ; IEC primitives fastload.c needs took their place.
        jmp _iec_set_fnadr                  ; $FF9B  svc 9
        jmp _iec_set_fnlen                  ; $FF9E  svc 10
        jmp _iec_command_raw                ; $FFA1  svc 11  (table ends $FFA3)
