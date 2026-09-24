; far_util.s - the doors into the util bank's services, linked into every
; bank that uses them (edit, and files for cat/less).
;
; Each stub is a cc65 __fastcall__ function of one argument (A/X), so the C side
; calls it like any other function (src/banks/basic_tok.h has the prototypes).
; It names the target in Y and jumps to far_call through SVC 13, which serves
; the util bank, runs the entry, serves this bank again and returns the
; entry's A/X -- or $FFFF when no util bank answered (src/far.inc).
;
; far_svc is bound to $FFA7 by each caller's cfg (EF: $9FA7, rebound by
; tools/make_ef_bank_cfg.py). The ids must match BANK_UTIL in src/shell.h and
; the entry order in crt0_util.s; test_far checks the entries.

.import far_svc
.export _far_detokenize, _far_tokenize

BANK_UTIL        = 1
UTIL_DETOKENIZE  = 6            ; basic_tok.h
UTIL_TOKENIZE    = 7

.segment "CODE"

_far_detokenize:
        ldy #(BANK_UTIL << 5) | UTIL_DETOKENIZE
        jmp far_svc

_far_tokenize:
        ldy #(BANK_UTIL << 5) | UTIL_TOKENIZE
        jmp far_svc
