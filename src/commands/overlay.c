/* overlay.c - tardis overlay command dispatch (PLAN.md backlog #4).
 *
 * Overlay commands don't live in the 16KB shell ROM. Their code sits in
 * two 8KB overlays flash sets on the One ROM (build/overlays_a/b.bin, packed
 * from src/overlays/), and the resident side here is only a thin thunk: pick
 * the overlay's flash set (OVL_MB_SET), fetch its 256-byte page(s) into the
 * cache (via the SLOT_PEEK transport in src/rbcp/launch.s), then call it. A
 * one-entry cache makes repeat invocations free -- no device round-trip.
 *
 * Only works on One ROM hardware with the host-control plugin; anywhere
 * else (VICE, plain `make onerom` firmware) the RBCP handshake times out
 * and the thunk reports the failed stage instead of calling garbage.
 */
#include "shell.h"
#include "commands/overlay.h"
#include "overlay_pages.h"      /* generated: ABOUT_PAGE/FILES_FIRST_PAGE/EDIT_FIRST_PAGE */

#define CR 0x0D

/* src/rbcp/launch.s: fetch OVL_MB_CNT pages starting at OVL_MB_PAGE to
   page OVL_MB_DST<<8, one session for the whole run.
   0 = ok, 1 = enter failed, 2 = load failed, 3 = peek failed, 4 = exit. */
unsigned char overlay_fetch_multi(void);
#define OVL_MB_PAGE (*(unsigned char *)0x02C0)
#define OVL_MB_CNT  (*(unsigned char *)0x02C1)
#define OVL_MB_DST  (*(unsigned char *)0x02C2)
#define OVL_MB_SET  (*(unsigned char *)0x02C3)  /* flash set for the fetch */

/* The RBCP transport over the One ROM bus glitches occasionally: a fetch can
   fail at enter (stage 1), peek (stage 3), or come back with corrupt data
   (stage 5 = wrong magic). These are transient, so retry the whole fetch a few
   times -- each attempt restarts with rbcp_reset, which flushes device state.
   The protocol's own retries only cover the command-token poll, not these. */
#define OVL_RETRIES 2   /* was 5, papering over badline-corrupted RBCP frames;
                           the vic guard root-caused that (v0.1.56) and hardware
                           confirms fetches no longer fail, so 2 is a safety net
                           and a genuine failure reports ~2.5x sooner */

/* This module lives in the default CODE/RODATA (the BASIC ROM half), NOT in
   CODE2: the retry loops pushed CODE2 into the reserved $FE00 RBCP back-channel
   window (test_rbcp::test_back_channel_window_is_free_fill). The BASIC half has
   ample room; the cross-bank calls to the launch.s fetch trampolines are fine
   (both ROM halves are always mapped). */

/* --- multi-page overlays at $8800 (about, edit, files, dir) --------------
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

/* Fetch the multi-page overlay whose first page is `first_page` in flash `set`
   into $8800 and confirm its magic. 0 = ready to call $8800, else a
   failed-stage code. */
static unsigned char mp_fetch(unsigned char first_page, const char *magic,
                              unsigned char set)
{
    unsigned char rc, n, tries;

    if (mp_cached(magic))
        return 0;
    /* Retry the whole fetch on a transient glitch (stage 1/3/5). Each attempt
       reloads page 1 from scratch and re-validates the magic. */
    for (tries = OVL_RETRIES, rc = 1; tries && rc; --tries) {
        OVL_MB_SET  = set;
        OVL_MB_PAGE = first_page;
        OVL_MB_CNT  = 1;
        OVL_MB_DST  = 0x88;
        rc = overlay_fetch_multi();
        if (rc == 0 && mp_cached(magic)) {
            n = OVL8_BASE[7];                   /* total pages */
            if (n > 1) {
                OVL_MB_CNT = n - 1;             /* mailbox stepped past page 1 */
                rc = overlay_fetch_multi();
            }
        } else if (rc == 0) {
            rc = 5;                             /* fetched, but no magic */
        }
        if (rc == 0 && !mp_cached(magic))
            rc = 5;
    }
    return rc;
}

static void mp_failed(unsigned char rc)
{
    puts_raw("overlay load failed, stage ");
    chrout('0' + rc);
    chrout(CR);
}

/* about: a self-contained asm overlay that clears the screen and prints its
   description. Multi-page like the others now (the text outgrew one page). */
void cmd_about(int argc, char *argv[])
{
    unsigned char rc;

    (void)argc; (void)argv;
    rc = mp_fetch(ABOUT_FIRST_PAGE, "abt1", ABOUT_SET);
    if (rc != 0) {
        mp_failed(rc);
        return;
    }
    OVL8_ENTRY();
}

void cmd_edit(int argc, char *argv[])
{
    unsigned char rc, n;
    const char *name;

    rc = mp_fetch(EDIT_FIRST_PAGE, "edt1", EDIT_SET);
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
    unsigned char rc = mp_fetch(FILES_FIRST_PAGE, "fil1", FILES_SET);

    if (rc != 0) {
        mp_failed(rc);
        return;
    }
    OVL8_ENTRY();
}

/* Like run_files_overlay, but a fetch failure is silent: used by the boot-
   time device identify, where "overlay load failed" would deface the banner
   (and on VICE -- no One ROM -- would print at every boot). The prompt just
   falls back to the bare unit number. */
void run_files_overlay_quiet(void)
{
    if (mp_fetch(FILES_FIRST_PAGE, "fil1", FILES_SET) == 0)
        OVL8_ENTRY();
}


/* Run the color-picker overlay. `which` (0 border, 1 bg, 2 text) goes in the
   $02D1 mailbox the overlay reads. */
void run_picker(unsigned char which)
{
    unsigned char rc;

    *(unsigned char *)0x02D1 = which;
    rc = mp_fetch(PICKER_FIRST_PAGE, "pic1", PICKER_SET);
    if (rc != 0) {
        mp_failed(rc);
        return;
    }
    OVL8_ENTRY();
}

