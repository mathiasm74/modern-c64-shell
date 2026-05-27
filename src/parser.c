/* parser.c - command-line tokenizer (see parser.h).
 *
 * Splits `line` in place on whitespace, with "double quotes" grouping a run
 * (including its spaces) into one token. We write NULs at token ends and point
 * argv into the buffer rather than copying -- there is no heap, and the line
 * buffer outlives the parse. The shell line is at most LINEMAX chars (capped by
 * readline), so there is no length handling to do here beyond the MAX_ARGS cap.
 */
#include "parser.h"

#define is_space(c) ((c) == ' ' || (c) == '\t')

void parse_line(char *p, struct command_line *cl)
{
    cl->argc = 0;

    for (;;) {
        while (is_space(*p))            /* skip the gap before a token */
            ++p;
        if (*p == '\0')
            break;                      /* end of line: done */
        if (cl->argc >= MAX_ARGS)
            break;                      /* table full: drop trailing tokens */

        if (*p == '"') {
            cl->argv[cl->argc++] = ++p; /* token starts after the open quote */
            while (*p != '\0' && *p != '"')
                ++p;
        } else {
            cl->argv[cl->argc++] = p;
            while (*p != '\0' && !is_space(*p))
                ++p;
        }
        if (*p != '\0')                 /* terminate this token, step past the */
            *p++ = '\0';                /* delimiter (quote, space, or tab)    */
    }

    if (cl->argc < MAX_ARGS)            /* NULL-terminate argv, argv-style */
        cl->argv[cl->argc] = 0;
}
