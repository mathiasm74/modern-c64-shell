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
void fastload_epyx_install(void);
void fastload_epyx_mark_unsupported(void);
unsigned char fastload_epyx_send_header(const char *name, unsigned char namelen);
unsigned int __fastcall__ epyx_recv_prg(void);

void disk_fload(void)
{
    unsigned int end;
    char **argv = BD_ARGV;

    DM_STAT = DM_FAILED;
    if (BD_ARGC < 2) {
        usage("fload <name>");
        return;
    }
    DM_NLEN = fold_name(DM_NAME, argv[1]);

    fastload_set_device(MB_DEV);
    fastload_epyx_install();
    if (iec_status() & ST_NODEV) {
        report_no_device();
        return;
    }
    if (fastload_epyx_send_header((const char *)DM_NAME, DM_NLEN) != 0) {
        fastload_epyx_mark_unsupported();
        puts_bank("fast load not supported");
        k_chrout(CR);
        return;
    }
    end = epyx_recv_prg();
    if (end == 0) {                     /* fewer than 3 bytes -> failure */
        /* $03A4: the receiver stopped because the program reached this bank's
           own RAM. Say so -- "fast load failed" would send the user hunting a
           bus problem that isn't there. */
        puts_bank(*(unsigned char *)0x03A4 ? "program too large"
                                           : "fast load failed");
        k_chrout(CR);
        return;
    }
    DM_START = *(unsigned int *)0x02AF; /* LADRL/LADRH, set by the ASM */
    DM_END = end;

    /* The Epyx stream can't tell a dead bus from EOF (a yank reads a clean-
       looking truncated EOF), so verify the drive is still on the bus before
       trusting the result: TALK its command channel and check ST. */
    iec_set_fa(MB_DEV);
    iec_set_sa(15);
    iec_chkin();
    iec_clrchn();
    if (iec_status() & (ST_NODEV | ST_TIMEOUT)) {
        puts_bank("fast load failed");
        k_chrout(CR);
        return;
    }

    if (DM_START < 0xCF00 && DM_END > 0xCE00)
        TC_OK = 0;                      /* the load overwrote the cache page */
    DM_STAT = DM_OK;
    report_loaded("Fast-loaded $");
}


/* --- load ------------------------------------------------------------------
 *
 * Standard IEC load: per-byte handshaked, so it is bit-perfect. The Epyx fast
 * path is `fload` above -- its timed 2-bit receiver is only reliable on some
 * drives/links, and on the user's Meatloaf it jitters bits and scatters
 * corruption through the file (bogus BASIC line numbers, mangled tokens),
 * which a per-byte program then trips over. `load` stays the safe, always-
 * correct default, so `run` builds on a clean program.
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

void disk_load(void)
{
    unsigned char lo, hi, bc, n = 0;
    unsigned char *p;
    char **argv = BD_ARGV;

    DM_STAT = DM_REPORTED;
    if (BD_ARGC < 2) {
        usage("load <name>");
        return;
    }
    /* Not fold_name'd: `load` passes the name as typed (the IEC layer folds it
       on the way out), and it may be longer than a 16-char CBM name. */
    while (argv[1][n] && n < 40) {
        DM_NAME[n] = argv[1][n];
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
