/* overlay.c - tardis overlay command dispatch (PLAN.md backlog #4).
 *
 * Overlay commands don't live in the 16KB shell ROM. Their code sits in
 * the overlays flash set on the One ROM (build/overlays.bin, packed from
 * src/overlays/), and the resident side here is only a thin thunk: fetch
 * the command's 256-byte page into the overlay cache at $CE00 (via the
 * SLOT_PEEK transport in src/rbcp/launch.s), then call it. A one-entry
 * cache makes repeat invocations free -- no device round-trip.
 *
 * Only works on One ROM hardware with the host-control plugin; anywhere
 * else (VICE, plain `make onerom` firmware) the RBCP handshake times out
 * and the thunk reports the failed stage instead of calling garbage.
 */
#include "shell.h"
#include "commands/overlay.h"
#include "overlay_pages.h"      /* generated: ABOUT_PAGE/FILES_FIRST_PAGE/EDIT_FIRST_PAGE */

#define CR 0x0D

/* src/rbcp/launch.s: fetch overlay page `page` into the cache.
   0 = ok, 1 = enter failed, 2 = load failed, 3 = peek failed,
   4 = exit failed. */
unsigned char __fastcall__ overlay_fetch_page(unsigned char page);

/* src/rbcp/launch.s: fetch OVL_MB_CNT pages starting at OVL_MB_PAGE to
   page OVL_MB_DST<<8, one session for the whole run. Same return codes. */
unsigned char overlay_fetch_multi(void);
#define OVL_MB_PAGE (*(unsigned char *)0x02C0)
#define OVL_MB_CNT  (*(unsigned char *)0x02C1)
#define OVL_MB_DST  (*(unsigned char *)0x02C2)

/* The cache is one 256-byte page; its first byte is the entry point. */
#define OVERLAY_ENTRY ((void (*)(void))0xCE00)

#define PAGE_NONE 0xFF
static unsigned char cached_page = PAGE_NONE;   /* DATA: survives via copydata */

#pragma code-name (push, "CODE2")
#pragma rodata-name (push, "RODATA2")

/* Fetch (if not cached) and run the single-page overlay in page `page`. */
static void overlay_run(unsigned char page)
{
    unsigned char rc;

    if (cached_page != page) {
        rc = overlay_fetch_page(page);
        if (rc != 0) {
            cached_page = PAGE_NONE;
            puts_raw("overlay load failed, stage ");
            chrout('0' + rc);
            chrout(CR);
            return;
        }
        cached_page = page;
    }
    OVERLAY_ENTRY();
}

void cmd_about(int argc, char *argv[])
{
    (void)argc; (void)argv;
    overlay_run(0);
}

/* --- multi-page C overlays at $8800 (edit, files) ------------------------
 *
 * These cc65-compiled overlays live at $8800+ in user RAM. The cache is
 * validated by the 4-byte magic in the overlay's own header (offset +3), so
 * a `load`ed program that clobbered user RAM just forces a refetch; the page
 * count (offset +7) says how much to fetch. edit and files share the $8800
 * region (not used at once) and are told apart by their magic. Start pages
 * come from the generated overlay_pages.h, not a hardcoded number.        */
#define OVL8_BASE  ((unsigned char *)0x8800)
#define OVL8_ENTRY ((void (*)(void))0x8800)
#define EDIT_FN_MB ((unsigned char *)0x02D0)    /* len, then chars */

static unsigned char mp_cached(const char *magic)
{
    return OVL8_BASE[3] == magic[0] && OVL8_BASE[4] == magic[1] &&
           OVL8_BASE[5] == magic[2] && OVL8_BASE[6] == magic[3];
}

/* Fetch the multi-page overlay whose first page is `first_page` into $8800 and
   confirm its magic. 0 = ready to call $8800, else a failed-stage code. */
static unsigned char mp_fetch(unsigned char first_page, const char *magic)
{
    unsigned char rc, n;

    if (mp_cached(magic))
        return 0;
    OVL_MB_PAGE = first_page;
    OVL_MB_CNT  = 1;
    OVL_MB_DST  = 0x88;
    rc = overlay_fetch_multi();
    if (rc == 0 && mp_cached(magic)) {
        n = OVL8_BASE[7];                       /* total pages */
        if (n > 1) {
            OVL_MB_CNT = n - 1;                 /* mailbox stepped past page 1 */
            rc = overlay_fetch_multi();
        }
    } else if (rc == 0) {
        rc = 5;                                 /* fetched, but no magic */
    }
    if (rc == 0 && !mp_cached(magic))
        rc = 5;
    return rc;
}

static void mp_failed(unsigned char rc)
{
    puts_raw("overlay load failed, stage ");
    chrout('0' + rc);
    chrout(CR);
}

void cmd_edit(int argc, char *argv[])
{
    unsigned char rc, n;
    const char *name;

    rc = mp_fetch(EDIT_FIRST_PAGE, "edt1");
    if (rc != 0) {
        mp_failed(rc);
        return;
    }
    /* hand the filename (if any) to the overlay via the mailbox */
    n = 0;
    if (argc > 1) {
        name = argv[1];
        while (name[n] && n < 16) {
            EDIT_FN_MB[1 + n] = name[n];
            ++n;
        }
    }
    EDIT_FN_MB[0] = n;
    OVL8_ENTRY();
}

/* Run the files overlay (cat/less/cp/mv/rm). The fs.c thunk fills the mailbox
   first, then calls this. */
void run_files_overlay(void)
{
    unsigned char rc = mp_fetch(FILES_FIRST_PAGE, "fil1");

    if (rc != 0) {
        mp_failed(rc);
        return;
    }
    OVL8_ENTRY();
}

/* Run the dir overlay (dir/ls/pwd). The fs.c thunk fills the mailbox first. */
void run_dir_overlay(void)
{
    unsigned char rc = mp_fetch(DIR_FIRST_PAGE, "dir1");

    if (rc != 0) {
        mp_failed(rc);
        return;
    }
    OVL8_ENTRY();
}

#pragma rodata-name (pop)
#pragma code-name (pop)
