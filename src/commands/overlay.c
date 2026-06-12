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

/* Fetch (if not cached) and run the overlay in page `page`. */
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

/* --- edit: the multi-page C overlay (src/overlays/edit.c) ----------------
 *
 * Lives at $8800+ in user RAM; its first page starts at overlay page
 * EDIT_FIRST_PAGE (right after about's page 0 -- the Makefile's OVERLAYS
 * order defines this). The cache is validated by the magic in the
 * overlay's own header rather than a tag variable, so a `load`ed program
 * that clobbered user RAM just forces a refetch. The header's page count
 * tells us how much to fetch: one page first, then the rest.            */
#define EDIT_FIRST_PAGE 1
#define EDIT_BASE   ((unsigned char *)0x8800)
#define EDIT_ENTRY  ((void (*)(void))0x8800)
#define EDIT_FN_MB  ((unsigned char *)0x02D0)   /* len, then chars */

static unsigned char edit_cached(void)
{
    return EDIT_BASE[3] == 'e' && EDIT_BASE[4] == 'd' &&
           EDIT_BASE[5] == 't' && EDIT_BASE[6] == '1';
}

void cmd_edit(int argc, char *argv[])
{
    unsigned char rc, n;
    const char *name;

    if (!edit_cached()) {
        OVL_MB_PAGE = EDIT_FIRST_PAGE;
        OVL_MB_CNT  = 1;
        OVL_MB_DST  = 0x88;
        rc = overlay_fetch_multi();
        if (rc == 0 && edit_cached()) {
            n = EDIT_BASE[7];                   /* total pages */
            if (n > 1) {
                /* mailbox stepped to page+1 / dst+1 by the first fetch */
                OVL_MB_CNT = n - 1;
                rc = overlay_fetch_multi();
            }
        } else if (rc == 0) {
            rc = 5;                             /* fetched, but no magic */
        }
        if (rc != 0 || !edit_cached()) {
            puts_raw("overlay load failed, stage ");
            chrout('0' + rc);
            chrout(CR);
            return;
        }
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
    EDIT_ENTRY();
}

#pragma rodata-name (pop)
#pragma code-name (pop)
