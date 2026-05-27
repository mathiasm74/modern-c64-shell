/* iec.h - C view of the IEC serial-bus primitives in iec.s.
 *
 * Minimal, one-argument-at-a-time interface (matching cc65's calling
 * convention): set the device and channel, point at a filename, then open,
 * switch the drive to talk, and read bytes until the status shows EOI.
 */
#ifndef IEC_H
#define IEC_H

#define ST_TIMEOUT 0x02         /* iec_status() bit: read timed out (no data) */
#define ST_EOI     0x40         /* iec_status() bit: end of file/transfer     */
#define ST_NODEV   0x80         /* iec_status() bit: no device responded      */

void iec_set_fa(unsigned char dev);     /* device number (e.g. 8)          */
void iec_set_sa(unsigned char sa);      /* secondary address / channel     */
void iec_setname(const char *name);     /* NUL-terminated, length measured */

void iec_open(void);            /* LISTEN, send open-secondary + name, UNLISTEN */
void iec_chkin(void);           /* TALK + secondary, turn the bus around        */
unsigned char iec_getbyte(void);/* receive one byte (ACPTR); sets EOI in status */
void iec_close(void);           /* LISTEN, send close-secondary, UNLISTEN       */
void iec_clrchn(void);          /* UNTALK and release the bus                   */
unsigned char iec_status(void); /* the I/O status byte (ST)                     */

#endif /* IEC_H */
