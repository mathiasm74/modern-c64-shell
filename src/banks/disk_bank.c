/* disk_bank.c - the DISK BANK's C side (docs/ROM-EXPANSION.md).
 *
 * STAGE 1 SKELETON: proves the C-bank-at-$A000 infrastructure (cfg/disk_bank.cfg
 * + crt0_disk.s) links and runs from served ROM with its state in RAM. The real
 * cluster -- dir/ls/pwd, the Epyx protocol, and the fload/run fast path -- moves
 * in here in the following stages, at which point these stubs are replaced by
 * the moved bodies.
 *
 * Bank rules (see cfg/disk_bank.cfg): code+rodata are served ROM at $A000, so
 * nothing here may write to a $A000-$BFFF address; writable globals are DATA
 * (copied down to RAM by the crt0) or BSS (plain RAM). The machine is reached
 * through the resident KERNAL stubs (k_chrout) and the resident IEC services in
 * the SVC table -- never base BASIC-half routines, which are swapped out while
 * this bank is served.
 */

void k_chrout(unsigned char c);
unsigned char k_getin(void);

#define CR 0x0D

/* Initialized writable global: lives in DATA, so it exercises the crt0's
   ROM->RAM copydata. If this reads back as 'D' the copy worked; a bank that
   tried to keep writable state in its ROM image would read the ROM byte but
   drop writes into the RAM underneath. */
static unsigned char tag = 'D';

static void puts_bank(const char *s)
{
    while (*s)
        k_chrout(*s++);
}

static void banner(const char *what)
{
    puts_bank("disk bank ");
    k_chrout(tag);                      /* proves DATA was copied down */
    k_chrout(':');
    k_chrout(' ');
    puts_bank(what);
    k_chrout(CR);
}

void disk_dir(void)   { banner("dir");   }
void disk_ls(void)    { banner("ls");    }
void disk_pwd(void)   { banner("pwd");   }
void disk_fload(void) { banner("fload"); }
