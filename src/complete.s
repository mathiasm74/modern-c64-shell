; complete.s - filename TAB completion: the readline side, in assembly.
;
; This was first written in C (shell.c complete_word, v0.1.58) and cc65
; rendered it at ~1.3KB of the BASIC ROM; the same logic hand-written is
; ~600 bytes. It stays in the BASIC half (the CODE segment, alongside the
; cc65 output) -- the KERNAL half is the scarcer resource. The behavior is
; pinned by test_lineedit's completion tests, written against the C version.
;
; Contract (docs/TAB-COMPLETION.md): complete the word at the cursor from
; the $CE00-$CFFF name cache the dir overlay fills (packed [len][chars]
; entries, uppercase). A unique match completes fully; several matches
; extend to the longest common prefix; a TAB that makes no progress lists
; the candidates ls-style and reprints the prompt + line. First word, no
; match, or invalid cache: return silently.
;
; ABI with readline (shell.c): the caller stores the line length and cursor
; position at CW_LEN/CW_POS, JSRs _tab_complete, and reads them back. The
; line buffer itself is shell.c's `line` (imported). CHROUT ($FFD2)
; preserves A/X/Y (screen.s), which the print loops below rely on.

.export _tab_complete
.import _line                   ; readline's edit buffer (shell.c)
.import _print_prompt           ; "<dev>[ name]> " (shell.c)

CHROUT  = $FFD2
CR      = $0D
CRSR_L  = $9D
LINEMAX = 80                    ; keep in step with shell.c

TC_OK    = $CE00                ; cache valid flag
TC_COUNT = $CE01                ; number of packed entries

; Zero-page walk pointers: $FB-$FE are the documented boot/loader scratch,
; free while readline is taking keystrokes (no IEC/fastload transfer runs).
ptr     = $FB                   ; $FB/$FC: current cache entry
firstm  = $FD                   ; $FD/$FE: first matching entry

; State block at $02B1-$02BB (free between the Epyx scratch ending at $02B0
; and the RBCP/NV mailboxes starting at $02C0).
CW_LEN  = $02B1                 ; ABI in/out: line length
CW_POS  = $02B2                 ; ABI in/out: cursor position
ws      = $02B3                 ; word start index
wl      = $02B4                 ; word length (start..cursor)
nlen    = $02B5                 ; current entry's name length
match_n = $02B6                 ; matches found
cl      = $02B7                 ; common completion length
kins    = $02B8                 ; characters to insert
colf    = $02B9                 ; lister column toggle
idx     = $02BA                 ; entries left to walk
jtmp    = $02BB                 ; scratch counter

.segment "CODE"

; --- helpers ---------------------------------------------------------------

; fold a typed character up / a cache byte down (letters only)
fold_up:
        cmp #'a'
        bcc @done
        cmp #'z'+1
        bcs @done
        and #$DF
@done:  rts

fold_down:
        cmp #'A'
        bcc @done
        cmp #'Z'+1
        bcs @done
        ora #$20
@done:  rts

; validate the entry at (ptr): carry clear + nlen set, or carry set = stop
; (bad length byte or the walk ran off the cache's two pages -- defensive,
; e.g. after a program was loaded over the cache)
entry_ok:
        lda ptr+1
        cmp #$D0
        bcs @bad
        ldy #0
        lda (ptr),y
        sta nlen
        beq @bad
        cmp #17
        bcs @bad
        clc
        rts
@bad:   sec
        rts

; step to the next entry: ptr += nlen + 1
entry_next:
        lda ptr
        sec                     ; the +1, via carry
        adc nlen
        sta ptr
        bcc @done
        inc ptr+1
@done:  rts

; carry set if the entry at (ptr) prefix-matches line[ws..ws+wl)
entry_match:
        lda nlen
        cmp wl
        bcc @no                 ; name shorter than the typed word
        lda wl
        beq @yes                ; empty word matches everything
        sta jtmp
        ldx ws
        ldy #1
@loop:  lda _line,x
        jsr fold_up
        cmp (ptr),y
        bne @no
        inx
        iny
        dec jtmp
        bne @loop
@yes:   sec
        rts
@no:    clc
        rts

; emit A cursor-lefts (A may be 0)
put_lefts:
        tax
        beq @done
@loop:  lda #CRSR_L
        jsr CHROUT
        dex
        bne @loop
@done:  rts

; print line[0..CW_LEN)
put_line:
        ldx #0
@loop:  cpx CW_LEN
        beq @done
        lda _line,x
        jsr CHROUT
        inx
        bne @loop
@done:  rts

; start a cache walk: ptr = first entry, idx = entry count
walk_init:
        lda #$02
        sta ptr
        lda #$CE
        sta ptr+1
        lda TC_COUNT
        sta idx
        rts

; --- main entry --------------------------------------------------------------

_tab_complete:
        lda TC_OK
        beq @out0
        lda TC_COUNT
        bne @on
@out0:  rts
@on:
        ; word start: scan back from the cursor to the previous space
        lda CW_POS
        sta ws
@back:  ldx ws
        beq @havews             ; hit the line start (ws = 0)
        lda _line-1,x
        cmp #' '
        beq @havews
        dec ws
        bne @back
@havews:
        lda ws
        beq @out1               ; first word = the command name: inert
        lda CW_POS
        sec
        sbc ws
        sta wl
        cmp #17
        bcc @go                 ; longer than any cacheable name: inert
@out1:  rts
@go:
        ; pass 1: count matches, remember the first, shrink the common length
        jsr walk_init
        lda #0
        sta match_n
@w1:    jsr entry_ok
        bcs @w1end
        jsr entry_match
        bcc @w1next
        lda match_n
        bne @w1more
        lda ptr                 ; first match: remember it, cl = its length
        sta firstm
        lda ptr+1
        sta firstm+1
        lda nlen
        sta cl
        bne @w1count            ; nlen >= 1: always taken
@w1more:
        lda nlen                ; cl = min(cl, nlen)
        cmp cl
        bcs @w1shrink
        sta cl
@w1shrink:                      ; shrink cl to the common prefix vs the first
        lda cl
        sec
        sbc wl
        beq @w1count            ; nothing beyond the typed word left
        sta jtmp
        ldy wl
        iny                     ; Y = 1 + j, starting at j = wl
@w1c:   lda (firstm),y
        cmp (ptr),y
        bne @w1cut
        iny
        dec jtmp
        bne @w1c
        beq @w1count
@w1cut: tya                     ; mismatch at offset Y = 1+j -> cl = j
        sec
        sbc #1
        sta cl
@w1count:
        inc match_n
@w1next:
        jsr entry_next
        dec idx
        bne @w1
@w1end:
        lda match_n
        bne @have
@out:   rts
@have:
        lda cl
        sec
        sbc wl
        bne @extend
        jmp @list               ; no progress to make: list if ambiguous
@extend:
        sta kins

        ; clip the insertion to LINEMAX
        lda CW_LEN
        clc
        adc kins
        cmp #LINEMAX+1
        bcc @fits
        lda #LINEMAX
        sec
        sbc CW_LEN
        sta kins
        bne @fits
        rts                     ; line already full
@fits:
        lda CW_POS
        cmp CW_LEN
        bne @mid

        ; append at the end: store + echo (CHROUT wraps rows, so a wrapped
        ; line keeps working -- same as typing)
        ldy wl
        iny                     ; Y = cache offset of the first missing char
        ldx CW_LEN
@app:   lda (firstm),y
        jsr fold_down
        sta _line,x
        jsr CHROUT
        inx
        iny
        dec kins
        bne @app
        stx CW_LEN
        stx CW_POS
        rts

@mid:   ; shift the tail right by kins (from the end, downward)
        ldx CW_LEN
@shift: cpx CW_POS
        beq @insert
        lda _line-1,x
        pha
        txa
        clc
        adc kins
        tay
        pla
        sta _line-1,y
        dex
        bne @shift              ; CW_POS >= 1 here (ws >= 1), so X can't wrap
@insert:
        lda kins
        sta jtmp
        ldy wl
        iny
        ldx CW_POS
@ins:   lda (firstm),y
        jsr fold_down
        sta _line,x
        inx
        iny
        dec jtmp
        bne @ins
        lda CW_LEN
        clc
        adc kins
        sta CW_LEN
        ; redraw, the same sequence as shell.c's redraw_line: back to the
        ; line start, reprint, trailing wipe cell, park after the insertion
        lda CW_POS
        jsr put_lefts
        jsr put_line
        lda #' '
        jsr CHROUT
        lda CW_POS
        clc
        adc kins
        sta CW_POS              ; the cursor's new logical position
        lda CW_LEN
        clc
        adc #1                  ; we're at len+1 (after the wipe cell)
        sec
        sbc CW_POS
        jsr put_lefts
        rts

@list:  ; several candidates, none extendable: list them ls-style
        lda match_n
        cmp #2
        bcc @outl               ; one exact match: nothing to do
        lda #CR
        jsr CHROUT
        jsr walk_init
        lda #0
        sta colf
@w2:    jsr entry_ok
        bcs @w2end
        jsr entry_match
        bcc @w2next
        lda nlen                ; print the name, lowercased
        sta jtmp
        ldy #1
@pn:    lda (ptr),y
        jsr fold_down
        jsr CHROUT
        iny
        dec jtmp
        bne @pn
        lda colf
        bne @row
        lda #20                 ; left column: pad out to the right one
        sec
        sbc nlen
        sta jtmp
@pad:   lda #' '
        jsr CHROUT
        dec jtmp
        bne @pad
        inc colf
        bne @w2next             ; colf = 1: always taken
@row:   lda #CR                 ; right column: end the row
        jsr CHROUT
        lda #0
        sta colf
@w2next:
        jsr entry_next
        dec idx
        bne @w2
@w2end:
        lda colf
        beq @nl                 ; dangling left-column name -> end its row
        lda #CR
        jsr CHROUT
@nl:    jsr _print_prompt
        jsr put_line
        lda CW_LEN
        sec
        sbc CW_POS
        jsr put_lefts           ; park the cursor where it was
@outl:  rts
