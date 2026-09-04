/* C64 code for boot menu
 *
 * Copyright (C) 2026 Holger Gryska <r107sl@web.de>
 * MIT License
 *
 ******************************************************************************
 * Derived from DraBrowse V1.0C 8 Bit (27.12.2009)
 * Copyright (C) 2009 Sascha Bader
 *
 * The code can be used freely as long as you retain
 * a notice describing original source and author.
 *
 * THE PROGRAMS ARE DISTRIBUTED IN THE HOPE THAT THEY WILL BE USEFUL,
 * BUT WITHOUT ANY WARRANTY. USE THEM AT YOUR OWN RISK!
 */

#include <stdio.h>
#include <c64.h>
#include "screen.h"
#include "rbcp.h"

#define REPEAT_DELAY 6                           // delay for scrolling (frames)

static const char rbcp[1024] = { 0x00 };         // rbcp back-channel region

/* string "One ROM Image Selection" (avoid PETSCII conversion) */
static const char scrHeader[] = { 79,110,101,32,82,79,77,32,73,109,97,103,101,
                                  32,83,101,108,101,99,116,105,111,110,0 };
/* string "Firmware" (avoid PETSCII conversion) */
static const char scrFooter[] = { 70,105,114,109,119,97,114,101,0 };

static const char msgError[32*6] = { "failed to enter rbcp cmd-resp   "
                                     "wrong rbcp protocol version     "
                                     "load previous selection failed  "
                                     "rbcp get flash slot info failed "
                                     "no kernals found to boot        "
                                     "rbcp get device version failed  " };

extern unsigned char error;
#pragma zpsym ("error");
extern unsigned char nrSets;
#pragma zpsym ("nrSets");
extern unsigned char selSet;
#pragma zpsym ("selSet");
unsigned char scrollTimer = 0;
unsigned char running = 1;

void printEntry(unsigned char menuEntry)
{
    if (menuEntry == selSet) { reverS(1); }
    else { reverS(0); }
    printSxy(2, menuEntry + 1, &rbcp[(menuEntry << 5) + RBCP_NAME]);
    reverS(0);
}

void printSets(void)
{
    unsigned char menuEntry;
    for (menuEntry = nrSets; menuEntry > 0; --menuEntry) {
        printEntry(menuEntry);
    }
}

void initScreen(void)
{
    reverS(0);                                   // intitialize screen
    textColor(BACKC);
    clrScr();
    VIC.ctrl1 |= 0x10;                           // enable screen
    drawFrame();
    reverS(1);
    printSxy(8, 0, scrHeader);

    if (error == 0x00) {    
        printSxy(12, SCREENH-1, scrFooter);      // print menu screen
        printSxy(21, SCREENH-1, &rbcp[RBCP_DEVICE_VERSION]);
        reverS(0);
        textColor(TEXTC);
        printSets();
    }
    else {
        reverS(0);                               // print error screen
        textColor(ERRORC);
        printSxy(2, 2, &msgError[--error << 5]);
        while(1);
    }
}

void updateSets(unsigned char lastSelected)
{
    printEntry(lastSelected);
    printEntry(selSet);
}

void handleInput(void)
{
    unsigned char curDown, anyShift, isEnter, lastSel;

    CIA1.pra = 0xFE;                             // row PA0: enter PB1 and cursor down PB7
    isEnter = !(CIA1.prb & 0x02);
    curDown = !(CIA1.prb & 0x80);

    CIA1.pra = 0xFD;                             // row PA1: left shift PB7
    anyShift = !(CIA1.prb & 0x80);
    CIA1.pra = 0xBF;                             // row PA6: right shift PB4
    anyShift |= !(CIA1.prb & 0x10);

    if (curDown) {
        if (scrollTimer == 0) {
            lastSel = selSet;
            if (anyShift) {                      // cursor up pressed
                if (--selSet == 0) ++selSet;
            } else {                             // cursor down pressed
                if (++selSet > nrSets) --selSet;  // LOCAL PATCH: cap at nrSets
            }                                    //   (was ==nrSets, capped one
                                                 //   short; safe now nrSets is
                                                 //   the last valid record)
            scrollTimer = REPEAT_DELAY;
            updateSets(lastSel);
        }
    } else { scrollTimer = 0; }

    if (isEnter) {                               // if enter pressed
        running = 0;                             //   leave menu and hand back selected set
    }

    if (scrollTimer > 0) --scrollTimer;
}

void main(void)
{
    /* LOCAL PATCH (modern-c64-shell): hide internal ROM sets from the menu.
     * The onerom-stock firmware carries overlay and alt-font sets that are not
     * meant to be booted directly; it labels them with a leading '~'. They are
     * a contiguous tail (record 0 = the bootloader itself is already skipped by
     * printSets), so clamp nrSets to the first '~'-labeled record -- leaving
     * just the bootable kernals (Tardis DOS / Stock C64 / JiffyDOS). */
    if (error == 0x00) {
        /* Hide internal sets (overlays, alt-font) -- a contiguous tail our
         * firmware labels with a leading '~'. Two cc65/C64 gotchas here:
         *  - rbcp[] is `const` (init 0) but the device fills it at runtime, so
         *    read through a volatile pointer or the load folds to 0.
         *  - compare against the raw ASCII byte 0x7E, NOT '~': cc65 -t c64
         *    translates char literals to PETSCII ('~' -> $B1), while the device
         *    stores the label in ASCII. (Upstream sidesteps this by writing its
         *    header strings as raw byte arrays.) */
        const volatile unsigned char *rec =
            (const volatile unsigned char *)rbcp + 32 + RBCP_NAME;  /* record 1 */
        unsigned char n = 1;
        while (n <= nrSets && *rec != 0x7E) { ++n; rec += 32; }     /* 0x7E = '~' */
        nrSets = n - 1;
    }

    initScreen();

    if (nrSets > 22) { nrSets = 22; }            // limit ROM sets to 22 incl boot kernal
    if (nrSets < selSet) { selSet = 1; }

    while (running)
    {    
        printSets();
        handleInput();
        waitVsync();                             // sync with screen to avoid flickering
    }
    return;                                      // selected ROM set in selSel
}