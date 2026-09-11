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

void dir_main(void);                    /* src/overlays/dir.c */

#define MB_CMD  (*(unsigned char *)0x02D0)      /* 0 dir, 1 ls, 2 pwd */
#define MB_DEV  (*(unsigned char *)0x02D1)

void disk_dir(void) { MB_CMD = 0; dir_main(); }
void disk_ls(void)  { MB_CMD = 1; dir_main(); }
void disk_pwd(void) { MB_CMD = 2; dir_main(); }

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
 * Mailbox in the unused tape buffer, clear of cd's $0340 path scratch:
 *   $0370       name length        $0381  status (see FL_* below)
 *   $0371-$0380 name (<=16)        $0382  load_start     $0384  load_end
 */
#define FL_NLEN  (*(unsigned char *)0x0370)
#define FL_NAME  ((const char *)0x0371)
#define FL_STAT  (*(unsigned char *)0x0381)
#define FL_START (*(unsigned int *)0x0382)
#define FL_END   (*(unsigned int *)0x0384)

#define FL_OK          0
#define FL_NO_DEVICE   1
#define FL_UNSUPPORTED 2
#define FL_FAILED      3

#define ST_TIMEOUT 0x02
#define ST_NODEV   0x80

void __fastcall__ iec_set_fa(unsigned char dev);
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

    FL_STAT = FL_FAILED;

    fastload_set_device(MB_DEV);
    fastload_epyx_install();
    if (iec_status() & ST_NODEV) {
        FL_STAT = FL_NO_DEVICE;
        return;
    }
    if (fastload_epyx_send_header(FL_NAME, FL_NLEN) != 0) {
        fastload_epyx_mark_unsupported();
        FL_STAT = FL_UNSUPPORTED;
        return;
    }
    end = epyx_recv_prg();
    if (end == 0)                       /* fewer than 3 bytes -> failure */
        return;
    FL_START = *(unsigned int *)0x02AF; /* LADRL/LADRH, set by the ASM */
    FL_END = end;

    /* The Epyx stream can't tell a dead bus from EOF (a yank reads a clean-
       looking truncated EOF), so verify the drive is still on the bus before
       trusting the result: TALK its command channel and check ST. */
    iec_set_fa(MB_DEV);
    iec_set_sa(15);
    iec_chkin();
    iec_clrchn();
    if (iec_status() & (ST_NODEV | ST_TIMEOUT))
        return;

    FL_STAT = FL_OK;
}
