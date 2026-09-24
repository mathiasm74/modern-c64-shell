/* basic_tok.c - BASIC V2 tokenizer and detokenizer, as util-bank SERVICES.
 *
 * These moved here from the edit bank when it filled up. The editor reaches
 * them with a far call (src/far.inc), so they are services, not commands, and
 * keep the rules that go with that:
 *
 *   - no BSS, no DATA, no zero page of our own. The RAM window and the cc65
 *     zero page belong to the CALLER while we run -- we are on its C stack,
 *     and bank_init is deliberately not run. Everything here is a local or a
 *     const table (RODATA stays in this bank's ROM, which is mapped while we
 *     run). test_far::test_services_own_no_ram checks the map.
 *   - every pointer we are handed points into RAM; the caller's ROM is gone.
 *   - never return 0xFFFF: far_call uses it to say the call failed.
 *
 * A tokenized program is, from its load address ($0801) onward, per line:
 *     link lo/hi   address of the next line; $0000 ends the program
 *     line# lo/hi
 *     bytes...     < $80 literal PETSCII, >= $80 a keyword token
 *     $00          end of line
 *
 * We carry our own keyword table: the stock BASIC ROM is exactly what this
 * shell replaced, so there is nothing to borrow at runtime. Tokens run $80..$CB
 * contiguously, so the table is just the keywords in order -- each stored with
 * the high bit set on its LAST character, which is how Commodore stored it too
 * and saves a separator byte per entry.
 */
#include "basic_tok.h"

#define CR_CH     0x0D
#define TOK_FIRST 0x80
#define TOK_LAST  0xCB
#define TOK_DATA  0x83
#define TOK_REM   0x8F

static const char basic_kw[] =
    "EN\xC4" "FO\xD2" "NEX\xD4" "DAT\xC1" "INPUT\xA3" "INPU\xD4" "DI\xCD"
    "REA\xC4" "LE\xD4" "GOT\xCF" "RU\xCE" "I\xC6" "RESTOR\xC5" "GOSU\xC2"
    "RETUR\xCE" "RE\xCD" "STO\xD0" "O\xCE" "WAI\xD4" "LOA\xC4" "SAV\xC5"
    "VERIF\xD9" "DE\xC6" "POK\xC5" "PRINT\xA3" "PRIN\xD4" "CON\xD4"
    "LIS\xD4" "CL\xD2" "CM\xC4" "SY\xD3" "OPE\xCE" "CLOS\xC5" "GE\xD4"
    "NE\xD7" "TAB\xA8" "T\xCF" "F\xCE" "SPC\xA8" "THE\xCE" "NO\xD4"
    "STE\xD0" "\xAB" "\xAD" "\xAA" "\xAF" "\xDE" "AN\xC4" "O\xD2"
    "\xBE" "\xBD" "\xBC" "SG\xCE" "IN\xD4" "AB\xD3" "US\xD2" "FR\xC5"
    "PO\xD3" "SQ\xD2" "RN\xC4" "LO\xC7" "EX\xD0" "CO\xD3" "SI\xCE"
    "TA\xCE" "AT\xCE" "PEE\xCB" "LE\xCE" "STR\xA4" "VA\xCC" "AS\xC3"
    "CHR\xA4" "LEFT\xA4" "RIGHT\xA4" "MID\xA4" "G\xCF";

/* Decimal line numbers by repeated subtraction: a divide would pull cc65's
   udiv runtime into the bank for five digits. */
static const unsigned int pow10[5] = { 10000, 1000, 100, 10, 1 };

/* --- detokenizer ----------------------------------------------------------
 *
 * Bytes inside quotes are NOT tokens (BASIC does not tokenize inside a string),
 * so the walk tracks quote state and passes those through untouched. Output
 * that would pass `room` is dropped, never written.
 */
#define EMIT(ch) do { if (o < room) dst[o++] = (unsigned char)(ch); } while (0)

unsigned int __fastcall__ basic_detokenize(struct detok_args *a)
{
    const unsigned char *raw = a->raw;
    unsigned char *dst = a->dst;
    unsigned int n = a->n, room = a->room;
    unsigned int off = 2, o = 0, line, p10;
    const char *kw;
    unsigned char c, k, quoted, d, lead;

    for (;;) {
        if (off + 3 >= n)
            break;
        if ((raw[off] | raw[off + 1]) == 0)
            break;                      /* $0000 link: end of program */
        off += 2;
        line = raw[off] | ((unsigned int)raw[off + 1] << 8);
        off += 2;

        lead = 0;
        for (k = 0; k < 5; ++k) {
            p10 = pow10[k];
            d = 0;
            while (line >= p10) {
                line -= p10;
                ++d;
            }
            if (d || lead || k == 4) {
                EMIT('0' + d);
                lead = 1;
            }
        }
        EMIT(' ');

        quoted = 0;
        while (off < n && (c = raw[off++]) != 0) {
            if (c == '"')
                quoted ^= 1;
            if (!quoted && c >= TOK_FIRST && c <= TOK_LAST) {
                kw = basic_kw;
                for (k = c - TOK_FIRST; k; --k)   /* skip to entry k */
                    while ((*kw++ & 0x80) == 0)
                        ;
                do {
                    d = (unsigned char)*kw++;
                    EMIT(d & 0x7F);
                } while ((d & 0x80) == 0);
            } else {
                EMIT(c);
            }
        }
        EMIT(CR_CH);
    }
    return o;
}

/* --- tokenizer --------------------------------------------------------------
 *
 * The inverse: turn an edited listing back into a program.
 *
 * Keyword matching is FIRST-MATCH IN TABLE ORDER, which is what BASIC does and
 * why the table's order matters: "INPUT#" precedes "INPUT" and "PRINT#"
 * precedes "PRINT", so the longer form wins where one is a prefix of another.
 * Input is folded to uppercase while comparing, so a listing typed in the
 * shell's lowercase reads the same as one that came from a real program.
 *
 * Inside quotes nothing is tokenized and nothing is folded: a string may
 * legitimately contain the letters of a keyword, and it may contain control
 * codes (cursor moves, colour changes) that must survive byte-for-byte.
 *
 * Two statements suspend tokenizing the same way BASIC's own CRUNCH does:
 * after REM to the end of the line, and after DATA to the next colon. Without
 * that, any keyword's letters appearing inside the text get eaten -- "DONE"
 * became D,<ON>,E -- which both changes the bytes of a program that merely
 * round-trips through the editor and breaks what READ returns from a DATA
 * item.
 */

/* Match a keyword at src[i]. Returns the token and sets *len to the
   characters consumed, or 0 if no keyword starts here. */
static unsigned char match_keyword(const unsigned char *src, unsigned int i,
                                   unsigned int dl, unsigned char *len)
{
    const char *p = basic_kw;
    unsigned char tok = TOK_FIRST;
    unsigned char n, c, k;

    for (;;) {
        n = 0;
        for (;;) {
            k = (unsigned char)p[n];
            c = (i + n < dl) ? src[i + n] : 0;
            if (c >= 'a' && c <= 'z')
                c -= 32;
            if ((k & 0x7F) != c) {
                n = 0xFF;               /* mismatch: try the next keyword */
                break;
            }
            if (k & 0x80) {             /* high bit marks the last character */
                *len = n + 1;
                return tok;
            }
            ++n;
        }
        if (n == 0xFF) {
            while ((*p++ & 0x80) == 0)  /* skip this entry */
                ;
            if (tok == TOK_LAST)
                return 0;
            ++tok;
        }
    }
}

unsigned int __fastcall__ basic_tokenize(struct tok_args *a)
{
    const unsigned char *src = a->src;
    unsigned char *dst = a->dst;
    unsigned int dl = a->len, room = a->room;
    unsigned int i = 0, n = 0;
    unsigned int line, prev = 0, prevlink = 0xFFFF, addr;
    unsigned char c, quoted, tok, klen, digits, first = 1, literal;

    while (i < dl) {
        while (i < dl && ((c = src[i]) == ' ' || c == CR_CH))
            ++i;                        /* blank lines and indentation */
        if (i >= dl)
            break;

        line = 0;
        digits = 0;
        while (i < dl) {
            c = src[i];
            if (c < '0' || c > '9')
                break;
            /* line = line*10, as shifts: a 16-bit multiply would pull cc65's
               mul runtime into this bank for one expression. */
            line = (line << 3) + (line << 1) + (unsigned int)(c - '0');
            ++digits;
            ++i;
        }
        if (!digits) {
            a->err = TOK_ERR_NO_NUMBER;
            return 0;
        }
        /* BASIC stores lines in ascending order and the link chain assumes it.
           Refuse rather than write a program that lists wrongly. */
        if (!first && line <= prev) {
            a->err = TOK_ERR_ORDER;
            return 0;
        }
        prev = line;
        first = 0;
        if (i < dl && src[i] == ' ')
            ++i;                        /* the space after the number */

        if (n + 5 >= room)
            goto too_large;
        if (prevlink != 0xFFFF) {       /* previous line links to this one */
            addr = 0x0801 + n;
            dst[prevlink] = (unsigned char)(addr & 0xFF);
            dst[prevlink + 1] = (unsigned char)(addr >> 8);
        }
        prevlink = n;
        dst[n++] = 0;                   /* link, patched when the next starts */
        dst[n++] = 0;
        dst[n++] = (unsigned char)(line & 0xFF);
        dst[n++] = (unsigned char)(line >> 8);

        quoted = 0;
        literal = 0;                    /* 1 = until ':' (DATA), 2 = to EOL (REM) */
        while (i < dl && (c = src[i]) != CR_CH) {
            if (n + 2 >= room)
                goto too_large;
            if (c == '"') {
                quoted ^= 1;
            } else if (!quoted && !literal) {
                tok = match_keyword(src, i, dl, &klen);
                if (tok) {
                    dst[n++] = tok;
                    i += klen;
                    if (tok == TOK_REM)
                        literal = 2;
                    else if (tok == TOK_DATA)
                        literal = 1;
                    continue;
                }
            }
            if (literal == 1 && c == ':')
                literal = 0;            /* DATA ends at the statement break */
            dst[n++] = c;
            ++i;
        }
        dst[n++] = 0;                   /* end of line */
        if (i < dl)
            ++i;                        /* consume the CR */
    }

    if (prevlink != 0xFFFF) {           /* last line links to the terminator */
        addr = 0x0801 + n;
        dst[prevlink] = (unsigned char)(addr & 0xFF);
        dst[prevlink + 1] = (unsigned char)(addr >> 8);
    }
    if (n + 2 >= room)
        goto too_large;
    dst[n++] = 0;                       /* $0000 link: end of program */
    dst[n++] = 0;
    return n;

too_large:
    a->err = TOK_ERR_TOO_LARGE;
    return 0;
}
