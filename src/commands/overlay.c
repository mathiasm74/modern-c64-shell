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

#pragma rodata-name (pop)
#pragma code-name (pop)
