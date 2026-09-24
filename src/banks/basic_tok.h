/* basic_tok.h - the BASIC V2 (de)tokenizer SERVICES in the util bank.
 *
 * The edit bank filled up, so the tokenizer and its keyword table moved to the
 * util bank, which the editor reaches with a far call (src/far.inc). Both sides
 * include this header: the util bank implements the two functions, the edit
 * bank declares them as far_* stubs (src/banks/far_util.s) with the same
 * signatures.
 *
 * A far call takes exactly one argument, so each takes a block of arguments.
 * The block lives in the CALLER's RAM (its C stack or BSS) and every pointer in
 * it must point into RAM: the caller's ROM is not mapped while the service runs.
 * A result of 0xFFFF means the call itself failed (no util bank answered).
 */
#ifndef BASIC_TOK_H
#define BASIC_TOK_H

/* util-bank JMP-table entries (crt0_util.s). */
#define UTIL_DETOKENIZE  6
#define UTIL_TOKENIZE    7

#define FAR_FAILED       0xFFFFU

/* Tokenized program (from its load address) -> listing text. */
struct detok_args {
    const unsigned char *raw;   /* the file, load address first      */
    unsigned int n;             /* its length                        */
    unsigned char *dst;         /* where the listing goes            */
    unsigned int room;          /* bytes available at dst            */
};

/* Listing text -> tokenized program (without its load address). */
struct tok_args {
    const unsigned char *src;   /* the listing, contiguous           */
    unsigned int len;
    unsigned char *dst;         /* where the program goes            */
    unsigned int room;
    unsigned char err;          /* on a 0 result: one of TOK_ERR_*   */
};

#define TOK_ERR_NO_NUMBER  1    /* a line without a line number      */
#define TOK_ERR_ORDER      2    /* lines out of ascending order      */
#define TOK_ERR_TOO_LARGE  3

/* Both return the number of bytes written to dst. detokenize stops short
   rather than overflow; tokenize returns 0 and sets err instead. */
unsigned int __fastcall__ basic_detokenize(struct detok_args *a);
unsigned int __fastcall__ basic_tokenize(struct tok_args *a);

unsigned int __fastcall__ far_detokenize(struct detok_args *a);
unsigned int __fastcall__ far_tokenize(struct tok_args *a);

#endif
