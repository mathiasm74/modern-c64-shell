/* disk_bank.c - the DISK BANK's entry layer (docs/ROM-EXPANSION.md).
 *
 * The bank's real content is the disk cluster, linked in from its existing
 * sources rather than rewritten: src/overlays/dir.c (dir/ls/pwd) and
 * src/fastload.c + the Epyx protocol asm. This file is only the glue between
 * the $A000 JMP table (crt0_disk.s) and those bodies.
 *
 * dir.c is compiled UNCHANGED, so it still selects its command through the
 * $02D0 mailbox byte the resident thunk used to set for the overlay. The bank's
 * per-command entry points set it here instead, which is why moving the cluster
 * needed no edits to a 567-line file. (Stage 4 can retire the mailbox byte
 * once the RAM overlay is gone and the JMP table is the only ABI.)
 *
 * Bank rules (see cfg/disk_bank.cfg): code+rodata are served ROM at $A000, so
 * nothing here may write to a $A000-$BFFF address; writable globals are DATA
 * (copied down to RAM by the crt0) or BSS (plain RAM). The machine is reached
 * through the resident KERNAL stubs and the resident IEC services in the SVC
 * table -- never base BASIC-half routines, which are swapped out while this
 * bank is served.
 */

void dir_main(void);                    /* src/banks/dir.c */

/* crt0_disk.s -- the KERNAL entry points, the only screen output a bank has
   (the shell's own puts_raw/chrout are in the swapped-out BASIC half). */
void __fastcall__ k_chrout(unsigned char c);

#define CR 0x0D

static void puts_bank(const char *s)
{
    while (*s)
        k_chrout(*s++);
}

#define MB_CMD  (*(unsigned char *)0x02D0)      /* 0 dir, 1 ls, 2 pwd */
#define MB_DEV  (*(unsigned char *)0x02D1)

/* Data-driven dispatch (shell.h, and bank_dispatch() in fs.c): the resident
   dispatcher publishes argc and argv here and calls our entry directly, so a
   bank command reads its OWN arguments and reports its OWN errors -- there is
   no resident thunk to do either. argv entries point into the shell's `line`
   buffer in RAM, which we can follow. */
#define BD_ARGC (*(unsigned char *)0x03A0)
#define BD_ARGV (*(char ***)0x03A1)

/* --- the fload/run fast path ------------------------------------------------
 *
 * Moved out of src/commands/fs.c: it was the last resident caller of the Epyx
 * protocol, so until it came here the protocol had to stay in the 16KB ROM.
 *
 * Only the PROTOCOL moved. The failure REPORTING stays resident -- this returns
 * a status code and the resident thunk prints it -- because the shell already
 * owns those strings and report_no_device(); duplicating them here would spend
 * bank bytes to save none. The name arrives already uppercase-folded for the
 * same reason (fold_name is resident and shared).
 *
 * Mailbox in the unused tape buffer, clear of cd's $0340 path scratch. Shared
 * by fload and load; the name field is 40 wide because `load` passes the name
 * as typed (fload's is fold_name'd to <=16):
 *   $0370       name length        $0399  status (see DM_* below)
 *   $0371-$0398 name (<=40)        $039A  load_start     $039C  load_end
 */
#define VIC_SPREN (*(unsigned char *)0xD015)
#define CIA1_ICR  (*(unsigned char *)0xDC0D)
#define DM_NLEN  (*(unsigned char *)0x0370)
#define DM_NAME  ((unsigned char *)0x0371)
#define DM_STAT  (*(unsigned char *)0x0399)
#define DM_START (*(unsigned int *)0x039A)
#define DM_END   (*(unsigned int *)0x039C)

/* Status handed back to the resident thunk, which owns the reporting -- except
   DM_REPORTED, where the drive's own error-channel message can only be read
   here and has already been printed. */
/* TAB-completion name cache valid flag ($CE00). A load that lands across it has
   overwritten the names, so drop it -- the resident thunks used to do this, but
   both loaders live here now. */
#define TC_OK (*(unsigned char *)0xCE00)

#define DM_OK          0
#define DM_NO_DEVICE   1
#define DM_UNSUPPORTED 2
#define DM_FAILED      3
#define DM_REPORTED    4

static void usage(const char *rest)
{
    puts_bank("usage: ");
    puts_bank(rest);
    k_chrout(CR);
}

static void report_no_device(void)
{
    unsigned char d = MB_DEV;

    puts_bank("device ");
    if (d >= 10) {
        k_chrout('0' + d / 10);
        d %= 10;
    }
    k_chrout('0' + d);
    puts_bank(" not present");
    k_chrout(CR);
}

static void print_hex_nybble(unsigned char n)
{
    n &= 0x0F;
    k_chrout(n < 10 ? '0' + n : 'a' + (n - 10));
}

static void print_hex16(unsigned int v)
{
    print_hex_nybble(v >> 12);
    print_hex_nybble(v >> 8);
    print_hex_nybble(v >> 4);
    print_hex_nybble(v);
}

/* Report "<what> $start-$end" for a completed load. */
static void report_loaded(const char *what)
{
    puts_bank(what);
    print_hex16(DM_START);
    puts_bank("-$");
    print_hex16(DM_END - 1);
    k_chrout(CR);
}

/* CBM filenames are uppercase PETSCII; fold as we copy into the mailbox.
   Moved here from fs.c with the commands that use it. */
static unsigned char fold_name(unsigned char *buf, const char *src)
{
    unsigned char n = 0;
    unsigned char c;

    while ((c = (unsigned char)src[n]) != 0 && n < 16) {
        if (c >= 'a' && c <= 'z')
            c -= 32;
        buf[n] = c;
        ++n;
    }
    return n;
}

void disk_dir(void) { MB_CMD = 0; dir_main(); }
void disk_ls(void)  { MB_CMD = 1; dir_main(); }
void disk_pwd(void) { MB_CMD = 2; dir_main(); }


#define ST_TIMEOUT 0x02
#define ST_EOI     0x40
#define ST_NODEV   0x80

void __fastcall__ iec_set_fa(unsigned char dev);
void __fastcall__ iec_setname(const char *name);
void iec_open(void);
void iec_close(void);
unsigned char iec_getbyte(void);
void __fastcall__ iec_set_sa(unsigned char sa);
void iec_chkin(void);
void iec_clrchn(void);
unsigned char iec_status(void);
void __fastcall__ fastload_set_device(unsigned char d);
unsigned char fastload_epyx_capable(void);
unsigned char fastload_drive_executes(void);
/* src/drive1541.s -- our own drive-side loader, for a drive that runs a real
   6502: a stock 1541, a Pi1541. It finds the file, walks its sector chain and
   ships it with the wire protocol fastload_recv.s already speaks. Verified in
   VICE against true drive emulation -- a real 6502 running real 1541 ROM --
   byte-perfect over 16KB and 65 sectors, repeatedly. */
unsigned char fastload_drive_install(const char *name, unsigned char namelen);
void fastload_epyx_install(void);
void fastload_epyx_mark_unsupported(void);
unsigned char fastload_epyx_send_header(const char *name, unsigned char namelen);
unsigned int __fastcall__ epyx_recv_prg(void);

/* Entry 5: probe the current device and record what it is (KL_MEATDEV in
   fastload.c). The stock swap calls this first, so KLOAD is only ever armed for
   a drive that has just answered as Meatloaf-class. */
void disk_probe(void)
{
    fastload_set_device(MB_DEV);
    fastload_epyx_capable();
}

/* The fast load, shared by `fload` and `load`. The name must already be in
   DM_NAME/DM_NLEN, fold_name'd. Prints only the progress dots and, on success,
   the "Fast-loaded" line: every failure is RETURNED, because what to say
   depends on the caller -- `fload` reports it, `load` quietly falls back to the
   standard path, which then reports whatever the drive itself says. */
#define FAST_OK      0
#define FAST_NONE    1          /* this drive has no fast path: nothing sent */
#define FAST_FAILED  2          /* tried, and it did not complete */
#define FAST_TOOBIG  3          /* the program ran into the bank's own RAM */
#define FAST_NODEV   4          /* nobody on the bus */

static unsigned char fast_load(void)
{
    unsigned char sprites;
    unsigned int end;

    fastload_set_device(MB_DEV);
    /* Two kinds of drive, two payloads, chosen by the probe.
       A Meatloaf-class drive CHECKSUMS what we upload and answers with its own
       implementation, so it gets the 75-byte fingerprint. A drive that runs a
       real 6502 gets real code (src/drive1541.s), which is what makes a stock
       1541 fast -- before it existed there was nothing to give one.
       PROBE BEFORE INSTALLING. Installing ends in an M-E, i.e. the drive
       EXECUTES what we uploaded -- and what we upload is 75 bytes of $EA
       fingerprint filler for Meatloaf, not real 6502. A drive that genuinely
       runs it (a real 1541, Pi1541, SD2IEC) sleds off the end and hangs until
       it is reset: `ls` worked, `fload` reported "not supported", and the
       drive was then dead. dir.c has always probed; this path did not, and it
       is the one `run <name>` uses too. */
    if (fastload_epyx_capable()) {
        fastload_epyx_install();
        if (iec_status() & ST_NODEV)
            return FAST_NODEV;
        if (fastload_epyx_send_header((const char *)DM_NAME, DM_NLEN) != 0) {
            fastload_epyx_mark_unsupported();
            return FAST_NONE;
        }
    } else if (fastload_drive_executes()) {
        /* The name goes up with the code, so there is no header to send: the
           drive never has to receive, only transmit. */
        if (fastload_drive_install((const char *)DM_NAME, DM_NLEN) != 0)
            return FAST_NODEV;
    } else if (iec_status() & ST_NODEV) {
        return FAST_NODEV;
    } else {
        return FAST_NONE;
    }
    /* Sprites steal VIC cycles exactly as badlines do, and the byte is
       cycle-locked, so any sprite enabled across a transfer would corrupt it.
       The shell itself never enables one, but a program loaded before a second
       fload can leave $D015 set -- so save, clear and restore it, the way the
       real cartridge does. Once per transfer; nothing per byte. */
    sprites = VIC_SPREN;
    VIC_SPREN = 0;
    /* Mask CIA1's timer IRQ for the transfer, as the real cartridge does
       ($7F -> $DC0D once per load). Restored to the KERNAL's $81 after. */
    CIA1_ICR = 0x7F;
    (void)CIA1_ICR;
    end = epyx_recv_prg();
    CIA1_ICR = 0x81;
    VIC_SPREN = sprites;
    if (end == 0)                       /* fewer than 3 bytes, or cut short */
        /* $03A4: the receiver stopped because the program reached this bank's
           own RAM -- not a bus problem, and not one a retry would fix. */
        return *(unsigned char *)0x03A4 ? FAST_TOOBIG : FAST_FAILED;
    DM_START = *(unsigned int *)0x02AF; /* LADRL/LADRH, set by the ASM */
    DM_END = end;

    /* The Epyx stream can't tell a dead bus from EOF (a yank reads a clean-
       looking truncated EOF), so verify the drive is still on the bus before
       trusting the result: TALK its command channel and check ST. */
    iec_set_fa(MB_DEV);
    iec_set_sa(15);
    iec_chkin();
    iec_clrchn();
    if (iec_status() & (ST_NODEV | ST_TIMEOUT))
        return FAST_FAILED;

    if (DM_START < 0xCF00 && DM_END > 0xCE00)
        TC_OK = 0;                      /* the load overwrote the cache page */
    DM_STAT = DM_OK;
    report_loaded("Fast-loaded $");
    return FAST_OK;
}

/* Say why a fast load did not happen. A failed one may have printed dots with
   no line end, so start a fresh line first. */
static void fast_report(unsigned char r)
{
    if (r == FAST_NODEV) {
        report_no_device();
        return;
    }
    if (*(unsigned char *)0x00D3)       /* PNTR: the cursor's column */
        k_chrout(CR);
    if (r == FAST_NONE)
        puts_bank("fast load not supported");
    else if (r == FAST_TOOBIG)
        puts_bank("program too large");
    else if (r == FAST_FAILED)
        puts_bank("fast load failed");
    else
        return;                         /* FAST_OK: already reported */
    k_chrout(CR);
}

/* fload <name> -- the fast path ONLY, and it says so when it cannot: the way to
   find out whether a drive is actually fast-loading, now that `load` falls back
   without comment. */
void disk_fload(void)
{
    char **argv = BD_ARGV;

    DM_STAT = DM_FAILED;
    if (BD_ARGC < 2) {
        usage("fload <name>");
        return;
    }
    DM_NLEN = fold_name(DM_NAME, argv[1]);
    fast_report(fast_load());
}


/* --- load ------------------------------------------------------------------
 *
 * Fast by default since v0.2.52 (see disk_load). Below the fast attempt is the
 * standard IEC load: per-byte handshaked, so it is bit-perfect on any drive --
 * the fallback, and all of `load --slow`. It was the only path `load` had while
 * the Epyx receiver was unreliable on the user's Meatloaf (it jittered bits
 * through the file); the badline pacing fixed that, and a real 1541 has had a
 * fast path since v0.2.48.
 *
 * Moved here from src/commands/fs.c with its two private helpers: the progress
 * dots, and report_drive_status -- which HAS to be here, because reporting the
 * drive's own reason means reading its error channel, and the failure paths
 * need it before the resident side regains control. The success message stays
 * resident (it reuses the shell's print_hex16).
 */
static unsigned char prog_dots;

static void progress(unsigned int total)
{
    unsigned char want = (unsigned char)(total >> 10);   /* a dot per 1024 bytes */

    while (prog_dots < want) {
        k_chrout('.');
        ++prog_dots;
    }
}

/* Read the drive's command/error channel (15) and print "<code> <message>" (the
   ,track,sector tail dropped), so a failed load shows the drive's real reason:
   a Meatloaf that's offline reports "74 drive not ready" (distinct from a
   genuinely missing file, "62 file not found"); a 1541 with no disk likewise
   says "74 drive not ready". Falls back to "read error" if no status comes
   back (a truly unresponsive drive). */
static void report_drive_status(void)
{
    unsigned char b, field = 0, got = 0, eat_sp = 0;

    iec_set_fa(MB_DEV);
    iec_set_sa(15);
    iec_setname("");
    iec_open();
    if (!(iec_status() & ST_NODEV)) {
        iec_chkin();
        for (;;) {
            b = iec_getbyte();
            if (iec_status() & ST_TIMEOUT)
                break;
            if (b == ',') {
                if (++field == 2)   /* stop after code + message */
                    break;
                k_chrout(' ');      /* "<code> <message>" */
                eat_sp = 1;         /* swallow the message's own leading space(s) */
            } else if (b != CR && b != 0) {
                if (eat_sp && b == ' ')
                    continue;
                eat_sp = 0;
                k_chrout(b);
                got = 1;
            }
            if (iec_status() & ST_EOI)
                break;
        }
    }
    iec_close();
    iec_clrchn();
    if (!got)
        puts_bank("read error");
    k_chrout(CR);
}

/* The bank's own DATA/BSS/C-stack floor (cfg/disk_bank.cfg). `load` runs FROM
   the bank, so a program allowed to grow past this would overwrite the live C
   stack underneath the loader -- a crash mid-transfer rather than a survivable
   clobber. (When load was resident this could not happen: a big load hit only
   the dir overlay, which self-heals, since overwriting its magic forces a
   re-fetch.) Refuse cleanly at the boundary instead. */
#define BANK_RAM_FLOOR 0x9D00

static unsigned char is_slow_flag(const char *a)
{
    const char *f = "--slow";

    while (*f && *a == *f) {
        ++a;
        ++f;
    }
    return *a == 0 && *f == 0;
}

/* load [--slow] <name> -- FAST BY DEFAULT. The fast path is tried first; if the
   drive has none, or the fast load does not complete, the standard path below
   runs instead without comment, and reports whatever the drive says -- so a
   missing file still reads "62 file not found", not "fast load failed".
   --slow goes straight to the standard path: per-byte handshaked, bit-perfect
   on any drive. `fload` is the fast path alone.

   Standard only, also: names longer than a CBM name (a Meatloaf URL or long
   path), which the fast header's 16 bytes cannot carry. */
void disk_load(void)
{
    unsigned char lo, hi, bc, i, n = 0, slow = 0;
    unsigned char *p;
    const char *name = 0;
    char **argv = BD_ARGV;

    DM_STAT = DM_REPORTED;
    for (i = 1; i < BD_ARGC; ++i) {
        if (argv[i][0] == '-' && argv[i][1] == '-') {
            if (!is_slow_flag(argv[i])) {
                usage("load [--slow] <name>");
                return;
            }
            slow = 1;
        } else if (!name) {
            name = argv[i];
        }
    }
    if (!name) {
        usage("load [--slow] <name>");
        return;
    }
    while (name[n])
        ++n;
    if (!slow && n <= 16) {
        DM_NLEN = fold_name(DM_NAME, name);
        i = fast_load();
        if (i == FAST_OK || i == FAST_NODEV || i == FAST_TOOBIG) {
            fast_report(i);             /* nothing a slow retry would change */
            return;
        }
        if (*(unsigned char *)0x00D3)   /* dots from a failed attempt */
            k_chrout(CR);
        DM_STAT = DM_REPORTED;          /* no fast path, or it failed: */
    }                                   /* quietly go the standard way */
    /* Not fold_name'd: the standard path passes the name as typed (the IEC
       layer folds it on the way out), and it may be longer than a CBM name. */
    n = 0;
    while (name[n] && n < 40) {
        DM_NAME[n] = name[n];
        ++n;
    }
    DM_NAME[n] = 0;
    DM_NLEN = n;

    iec_set_fa(MB_DEV);
    iec_set_sa(0);              /* channel 0: a program load */
    iec_setname((const char *)DM_NAME);
    iec_open();
    if (iec_status() & ST_NODEV) {
        report_no_device();
        return;
    }
    iec_chkin();

    lo = iec_getbyte();         /* the file's load address */
    /* An immediate EOI with no timeout means the drive opened the channel but
       streamed back no data: the file does not exist. (A genuine read fault --
       no disk, etc. -- sets the timeout bit instead and is reported as "read
       error" below.) Without this check a missing file reads as load address
       $0000 and prints a bogus "loaded $0000-$0000". */
    if ((iec_status() & ST_EOI) && !(iec_status() & ST_TIMEOUT)) {
        iec_close();
        iec_clrchn();
        report_drive_status();          /* the drive's reason (offline vs missing) */
        return;
    }
    hi = iec_getbyte();
    p = (unsigned char *)(lo | ((unsigned int)hi << 8));
    DM_START = (unsigned int)p;

    prog_dots = 0;
    bc = 0;
    for (;;) {                  /* the last byte arrives with EOI set */
        if ((unsigned int)p >= BANK_RAM_FLOOR) {
            iec_close();
            iec_clrchn();
            if (prog_dots)
                k_chrout(CR);
            puts_bank("program too large");
            k_chrout(CR);
            return;             /* DM_STAT is still DM_REPORTED */
        }
        *p++ = iec_getbyte();
        if (iec_status() & ST_EOI)
            break;
        if ((++bc & 63) == 0)   /* sample the running total every 64 bytes */
            progress((unsigned int)p - DM_START);
    }
    if (prog_dots)
        k_chrout(CR);           /* fresh line for the result message */

    iec_close();
    iec_clrchn();

    if (iec_status() & ST_TIMEOUT) {
        report_drive_status();      /* the drive's reason (no disk / offline / ...) */
        return;
    }

    DM_END = (unsigned int)p;
    if (DM_START < 0xCF00 && DM_END > 0xCE00)
        TC_OK = 0;                      /* the load overwrote the cache page */
    DM_STAT = DM_OK;
    report_loaded("loaded $");
}
