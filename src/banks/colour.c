/* colour.c - border / bg / text, and their interactive picker's entry layer.
 *
 * Lives in the UTIL BANK, with picker.c. Both had to move together, and so did
 * the value path, because of one hard rule: A BANK CANNOT CALL ANOTHER BANK.
 * Switching banks pulls the caller's own code out from under the running CPU,
 * and its return address points into what is no longer there. So the picker must
 * sit in the same image as whatever opens it -- which is these three commands
 * with no value. (That is also why the picker originally travelled with files.c:
 * it could not stay a RAM overlay that a bank would have to fetch.)
 *
 * It moved OUT of the files bank because that bank reached 97% while this one
 * sat at 29%. What made the move cheap is that the util bank's "no cc65 runtime"
 * property turned out to buy nothing: the bank RAM window ($9D00-$9FFF) is
 * already reserved by the disk and files banks, banks SHARE it, and the loaded
 * program's ceiling is $9CFF whether this bank uses it or not. The one real cost
 * would have been per-entry init on the TAB keystroke path, and crt0_util.s
 * avoids that by initialising only the C entries -- tab completion, `about` and
 * `debug` are assembly and still jump straight in.
 */

void picker_main(void);                 /* src/banks/picker.c */

#define VIC_BORDER (*(unsigned char *)0xD020)
#define VIC_BG     (*(unsigned char *)0xD021)
#define COLOR_REG  (*(unsigned char *)0x0286)   /* KERNAL text colour */
#define MB_WHICH   (*(unsigned char *)0x02D1)   /* what the picker reads */

#define BD_ARGC (*(unsigned char *)0x03A0)
#define BD_ARGV (*(char ***)0x03A1)

/* argv[1] as a small decimal. Anything non-numeric ends it, so "bg 3x" takes
   the 3 -- the same forgiving parse the files bank did. */
static unsigned char parse_dec(void)
{
    char **argv = BD_ARGV;
    const char *s = argv[1];
    unsigned char v = 0;

    while (*s >= '0' && *s <= '9') {
        v = (unsigned char)(v * 10 + (unsigned char)(*s - '0'));
        ++s;
    }
    return v;
}

static void colour(unsigned char which)
{
    unsigned char val;

    if (BD_ARGC < 2) {                  /* no value: open the picker */
        MB_WHICH = which;
        picker_main();
        return;
    }
    val = parse_dec() & 0x0F;
    if (which == 0)
        VIC_BORDER = val;
    else if (which == 1)
        VIC_BG = val;
    else
        COLOR_REG = val;
}

void ub_border(void) { colour(0); }
void ub_bg(void)     { colour(1); }
void ub_text(void)   { colour(2); }
