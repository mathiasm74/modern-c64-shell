/* C64 code for text screen IO
 *
 * Copyright (C) 2026 Holger Gryska <r107sl@web.de>
 * MIT License
 */

#include <stdarg.h>
#include <target.h>

/*****************************************************************************/
/*                                Definitions                                */
/*****************************************************************************/

#define TEXTC COLOR_WHITE
#define BACKC COLOR_ORANGE
#define SEARCHC COLOR_GRAY2
#define WARNC COLOR_YELLOW
#define ERRORC COLOR_LIGHTRED

#define SCREENH 25
#define SCREENW 40

/*****************************************************************************/
/*                                 Functions                                 */
/*****************************************************************************/

void __fastcall__ printCxy (unsigned char x, unsigned char y, char c);
/* print character at position x/y */

void __fastcall__ printSxy (unsigned char x, unsigned char y, const char* s);
/* print string of maximum length PRINTL or \0 terminated at position x/y */

void drawFrame (void);
/* draw line from lines 1-23 in colums 0 & 39 */

void clrScr (void);
/* clear screen and color RAMs (1kB) */

void waitVsync (void);
/* wait and sync with raster beam */

/*****************************************************************************/
/*                                  Macros                                   */
/*****************************************************************************/

#define borderColor(val) (*(unsigned char*)0xD020 = (val))
#define bgColor(val)     (*(unsigned char*)0XD021 = (val))
#define textColor(val)   (*(unsigned char*)0x286  = (val))
#define reverS(val)      (*(unsigned char*)0xC7   = (val) ? 0x80 : 0x00)
