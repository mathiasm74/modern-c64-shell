; files_dos.s - dos_send for the files bank's drive commands (files_entry.c).
;
; Joins argv[first..argc-1] with single spaces onto the command already begun
; in the $0340 scratch, then has files.c send it and print the drive's reply
; (files_main command 19). Assembly because cc65's argv walk cost ~190 bytes
; in a bank with barely more than that to spare; this is ~60.
;
; void __fastcall__ dos_send(unsigned char first);
;   A1L ($02D2) on entry: bytes already in the command (0 for `dos`, 1 for
;   "i"/"v", 2 for "n:"); on exit: the whole command's length.
;   first = 0xFF appends no arguments.

.export _dos_send
.import _files_main
.importzp ptr1, ptr2, tmp1, tmp2

DOS_CMD = $0340
DOS_MAX = 40                    ; the scratch is $0340-$0367
MB_CMD  = $02D0
A1L     = $02D2
BD_ARGC = $03A0
BD_ARGV = $03A1

.segment "CODE"

_dos_send:
        sta tmp1                ; first
        sta tmp2                ; the argument being copied
        lda BD_ARGV
        sta ptr2
        lda BD_ARGV+1
        sta ptr2+1
        ldx A1L                 ; X = bytes so far
@arg:   lda tmp2
        cmp BD_ARGC
        bcs @send               ; no more arguments (0xFF never starts)
        cmp tmp1
        beq @word               ; no space before the first word
        cpx #DOS_MAX
        bcs @word
        lda #' '
        sta DOS_CMD,x
        inx
@word:  lda tmp2
        asl a
        tay
        lda (ptr2),y            ; ptr1 = argv[tmp2]
        sta ptr1
        iny
        lda (ptr2),y
        sta ptr1+1
        ldy #0
@ch:    lda (ptr1),y
        beq @next
        cpx #DOS_MAX
        bcs @next
        sta DOS_CMD,x
        inx
        iny
        bne @ch
@next:  inc tmp2
        jmp @arg
@send:  stx A1L
        lda #19                 ; files.c: send $0340 on channel 15, show reply
        sta MB_CMD
        jmp _files_main
