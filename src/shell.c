/* shell.c - Phase 4 shell skeleton, the project's first C.
 *
 * main() prints a prompt, reads a line of input, and reports
 * "command not found" for whatever was typed, forever. There is no command
 * table yet; that arrives in Phase 5. Input and output go through the KERNAL
 * entry points via the thin asm shims in c_io.s -- we deliberately avoid
 * cc65's conio, which assumes the stock C64 KERNAL we replaced.
 *
 * Characters are PETSCII on the way in (what the keyboard scan delivers) and
 * on the way out (what CHROUT expects). Letter keys arrive as uppercase
 * PETSCII, which matches the uppercase ASCII in our string literals byte for
 * byte, so no translation is needed for the printable range we use.
 */

#define CR       0x0D            /* RETURN: submit the line                 */
#define DEL      0x14            /* DELETE: backspace                       */
#define PRINT_LO 0x20            /* printable PETSCII range we store/echo   */
#define PRINT_HI 0x7E
#define LINEMAX  80             /* one 40-col line wraps to two; 80 is plenty */

/* Implemented in c_io.s. */
void chrout(unsigned char c);
unsigned char getin(void);

/* The current command line, NUL-terminated by readline(). */
static char line[LINEMAX + 1];

/* Print a NUL-terminated string through CHROUT. */
static void puts_raw(const char *s)
{
    while (*s)
        chrout(*s++);
}

/* Read one line into `line`, echoing as we go; return its length.
 *
 * RETURN submits, DELETE backspaces, printable characters are stored and
 * echoed. Any other control code is passed straight to CHROUT (so e.g. a
 * clear-screen still works as you type) but is not added to the line. */
static unsigned char readline(void)
{
    unsigned char len = 0;
    unsigned char c;

    for (;;) {
        c = getin();
        if (c == 0)
            continue;                   /* nothing waiting */
        if (c == CR) {
            chrout(CR);
            line[len] = 0;
            return len;
        }
        if (c == DEL) {
            if (len > 0) {
                --len;
                chrout(DEL);
            }
            continue;
        }
        if (c >= PRINT_LO && c <= PRINT_HI) {
            if (len < LINEMAX) {
                line[len++] = c;
                chrout(c);              /* echo */
            }
            continue;
        }
        chrout(c);                      /* other control code: act, don't store */
    }
}

void main(void)
{
    for (;;) {
        chrout('>');
        chrout(' ');
        if (readline() == 0)
            continue;                   /* empty line: just reprompt */
        puts_raw("COMMAND NOT FOUND: ");
        puts_raw(line);
        chrout(CR);
    }
}
