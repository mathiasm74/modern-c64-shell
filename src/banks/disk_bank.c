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

void disk_dir(void) { MB_CMD = 0; dir_main(); }
void disk_ls(void)  { MB_CMD = 1; dir_main(); }
void disk_pwd(void) { MB_CMD = 2; dir_main(); }

/* The fload/run fast path (fload_program + fast_receive_prg, still resident in
   src/commands/fs.c) moves in here in stage 4, at which point this entry gets
   its body and cmd_fload/cmd_run route to it. The Epyx protocol it needs is
   already in this image. */
void disk_fload(void) { }
