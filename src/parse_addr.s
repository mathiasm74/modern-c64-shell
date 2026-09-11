; parse_addr.s - parse a number the way the shell's commands accept one:
; DECIMAL by default, HEX when prefixed with '$'. The C64 convention, so
; `sys 54301` matches the number a BASIC user would type and `sys $d41d` is the
; same register.
;
;   unsigned int __fastcall__ parse_addr(const char *s);
;   in:  A/X = string pointer (lo/hi)
;   out: A/X = value (lo/hi)
;
; Parsing stops at the first character that is not a digit of the active base
; (so a trailing NUL, space or junk simply ends the number) and an empty or
; unparseable string yields 0 -- the same behaviour the C version had.
;
; WHY ASSEMBLY: this was ~20 lines of C, but cc65 turned the 16-bit shifts and
; the x10 into 251 bytes -- the single largest helper in the resident ROM after
; the stock-swap glue. The obvious alternative was to move it into a bank, but
; that is wrong for `sys` specifically: `sys` is resident precisely so the
; routine it calls sees user RAM the shell has not disturbed, and a bank call
; writes its DATA/BSS/C-stack over $9C00-$9FFF. Rewriting keeps the contract and
; still reclaims most of the bytes.
;
; Uses cc65's zeropage scratch (ptr1/ptr2/tmp1/tmp2), which is exactly what it
; is for -- free between C statements, so no dedicated locations are burned.

.export _parse_addr
.importzp ptr1, ptr2, tmp1, tmp2

.segment "CODE2"                ; KERNAL half (the BASIC half is the tight one)

_parse_addr:
        sta ptr1
        stx ptr1+1
        lda #0
        sta ptr2                ; accumulated value
        sta ptr2+1
        ldy #0
        lda (ptr1),y
        cmp #'$'
        beq hex

; --- decimal ---------------------------------------------------------------
decnum: lda (ptr1),y
        beq done
        sec
        sbc #'0'
        cmp #10
        bcs done                ; not a decimal digit -> end of number
        pha                     ; save the digit

        ; value *= 10, as (value<<3) + (value<<1) -- a 16-bit multiply would
        ; pull cc65's mul runtime back in, which is what this file avoids.
        asl ptr2
        rol ptr2+1              ; x2
        lda ptr2
        sta tmp1
        lda ptr2+1
        sta tmp2                ; tmp = value*2
        asl ptr2
        rol ptr2+1              ; x4
        asl ptr2
        rol ptr2+1              ; x8
        clc
        lda ptr2
        adc tmp1
        sta ptr2
        lda ptr2+1
        adc tmp2
        sta ptr2+1              ; x8 + x2 = x10

        pla                     ; + digit
        clc
        adc ptr2
        sta ptr2
        bcc @nc
        inc ptr2+1
@nc:    iny
        bne decnum

done:   lda ptr2
        ldx ptr2+1
        rts

; --- hex ('$' prefix) ------------------------------------------------------
hex:    iny                     ; skip the '$'
@loop:  lda (ptr1),y
        beq done
        jsr nybble
        bcs done                ; not a hex digit -> end of number
        pha
        asl ptr2                ; value <<= 4
        rol ptr2+1
        asl ptr2
        rol ptr2+1
        asl ptr2
        rol ptr2+1
        asl ptr2
        rol ptr2+1
        pla
        ora ptr2
        sta ptr2
        iny
        bne @loop
        beq done                ; (always)

; A = character -> A = 0..15 with carry CLEAR, or carry SET if not a hex digit.
; Both sbc's run with carry already clear from the preceding cmp, hence the -1
; in each operand.
nybble:
        cmp #'0'
        bcc bad
        cmp #'9'+1
        bcs @alpha
        sbc #'0'-1              ; C=0 here: A - ('0'-1) - 1 = A - '0'
        clc
        rts
@alpha: ora #$20                ; fold A-F to a-f
        cmp #'a'
        bcc bad
        cmp #'f'+1
        bcs bad
        sbc #'a'-10-1           ; C=0 here: A - ('a'-10)
        clc
        rts
bad:    sec
        rts
