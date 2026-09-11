/* files_entry.c - the FILES BANK's entry layer (docs/ROM-EXPANSION.md).
 *
 * One entry per command, reached through the $A000 JMP table. Each does what
 * the resident thunk used to do -- check the argument count, marshal argv into
 * the mailbox files.c reads, and print the usage line -- so files.c itself
 * moved from RAM overlay to ROM bank essentially unchanged.
 *
 * With these here, data-driven dispatch (shell.h) means every one of these
 * commands costs the 16KB ROM nothing but its 4-byte dispatch row and its name.
 *
 * The mailbox is the same one the overlay used; only the filling moved. The
 * resident side still publishes the pieces a bank cannot reach for itself --
 * the default device and its remembered name, the addresses of those two
 * resident variables, the dispatch table, and argc/argv (bank_try in fs.c).
 */

void files_main(void);                  /* src/banks/files.c */
void picker_main(void);                 /* src/banks/picker.c */
void __fastcall__ k_chrout(unsigned char c);

#define CR 0x0D

/* Mailbox accessors -- absolute addresses (a base-pointer macro lets cc65
   reuse a loop-clobbered pointer register, mislanding a store/load). */
#define MB_CMD  (*(unsigned char *)0x02D0)
#define MB_DEV  (*(unsigned char *)0x02D1)      /* also the picker's "which" */
#define A1L     (*(unsigned char *)0x02D2)
#define A1      ((unsigned char *)0x02D3)       /* 16 chars */
#define A2L     (*(unsigned char *)0x02E3)
#define A2      ((unsigned char *)0x02E4)       /* 16 chars */

#define BD_ARGC (*(unsigned char *)0x03A0)
#define BD_ARGV (*(char ***)0x03A1)

static void puts_bank(const char *s)
{
    while (*s)
        k_chrout(*s++);
}

/* "usage: <rest>" -- the strings moved here with the commands, so they cost
   bank ROM instead of the 16KB image. */
static void usage(const char *rest)
{
    puts_bank("usage: ");
    puts_bank(rest);
    k_chrout(CR);
}

/* Copy argv[n] into a 16-byte mailbox arg; returns its length (0 if absent). */
static unsigned char arg_copy(unsigned char *dst, unsigned char n)
{
    char **argv = BD_ARGV;
    unsigned char i = 0;

    if (BD_ARGC > n) {
        while (argv[n][i] && i < 16) {
            dst[i] = argv[n][i];
            ++i;
        }
    }
    return i;
}

/* Fill both mailbox args from argv and run files.c's command `cmd`. */
static void run_args(unsigned char cmd)
{
    A1L = arg_copy(A1, 1);
    A2L = arg_copy(A2, 2);
    MB_CMD = cmd;
    files_main();
}

/* Commands needing at least `need` arguments; prints usage and skips if not. */
static void run_need(unsigned char cmd, unsigned char need, const char *use)
{
    if (BD_ARGC < need) {
        usage(use);
        return;
    }
    run_args(cmd);
}

void fb_cat(void)   { run_need(0, 2, "cat <name>");      }
void fb_less(void)  { run_need(1, 2, "less <name>");     }
void fb_cp(void)    { run_need(2, 3, "cp <src> <dst>");  }
void fb_mv(void)    { run_need(3, 3, "mv <old> <new>");  }
void fb_rm(void)    { run_need(4, 2, "rm <name>");       }
/* No-argument commands do NOT go through run_args: `help` reads the dispatch
   table pointer the resident side publishes at $02E4, which is the same byte
   range as mailbox arg 2. Leaving the mailbox alone keeps the two from
   colliding. */
static void run_bare(unsigned char cmd)
{
    MB_CMD = cmd;
    files_main();
}

void fb_status(void){ run_bare(6);  }
void fb_peek(void)  { run_args(12); }
void fb_poke(void)  { run_args(13); }
void fb_help(void)  { run_bare(15); }
void fb_device(void){ run_args(16); }
void fb_devices(void){ run_bare(18); }

/* Identify the default device quietly at boot (no output, failures swallowed);
   main() calls this through the bank like any other entry. */
void fb_identify(void) { run_bare(17); }

/* border / bg / text. With NO value they open the interactive colour picker,
   which is why picker.c is in this bank: a bank cannot fetch a RAM overlay,
   since the fetch machinery is resident BASIC-half code and is swapped out
   while we run. `which` (0/1/2) goes in $02D1, which the picker reads -- it
   does not need the device the resident side left there. */
static void colour(unsigned char which)
{
    if (BD_ARGC < 2) {
        MB_DEV = which;
        picker_main();
        return;
    }
    run_args(8 + which);
}

void fb_border(void) { colour(0); }
void fb_bg(void)     { colour(1); }
void fb_text(void)   { colour(2); }

/* cd <path> -- prebuild the whole drive command into the 40-byte scratch at
 * $0340 and pass only its length, because a path can exceed the 16-char
 * mailbox args (Meatloaf URLs). files.c's cd_path sends it on the command
 * channel.
 *
 * A relative path is sent as "CD:<path>". A path starting with '/' is absolute
 * (from the root); the CMD/Meatloaf form for that is "CD/<path>", so the path's
 * own leading slash yields "CD//" for the root or "CD//sub" for a subdir.
 * "cd //" is the special case for the flash root -- one level below "/" --
 * which the drive reaches with "CD<up-arrow>" (PETSCII $5E), not a slash path.
 */
#define CD_CMD ((unsigned char *)0x0340)

void fb_cd(void)
{
    char **argv = BD_ARGV;
    unsigned char i = 0, j;

    if (BD_ARGC < 2) {
        usage("cd <path>");
        return;
    }
    CD_CMD[i++] = 'c';
    CD_CMD[i++] = 'd';
    if (argv[1][0] == '/' && argv[1][1] == '/' && argv[1][2] == '\0') {
        CD_CMD[i++] = 0x5E;             /* "cd //" -> "CD<up-arrow>" flash root */
    } else {
        CD_CMD[i++] = (argv[1][0] == '/') ? '/' : ':';
        for (j = 0; argv[1][j] && i < 39; ++j)
            CD_CMD[i++] = argv[1][j];
    }
    A1L = i;                            /* prebuilt-command length (cmd at $0340) */
    MB_CMD = 7;
    files_main();
}
