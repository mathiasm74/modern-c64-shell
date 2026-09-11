/* svc.h - shell-services table (src/svc.s) for overlays.
 *
 * The table is a row of JMPs at a FIXED address ($FF80) into resident IEC /
 * Epyx routines. The overlay calls them as ordinary functions; their
 * addresses are bound by the SYMBOLS block in the overlay's link config
 * (cfg/overlay_dir.cfg), which pins each svc_* to $FF80 + n*3 -- so cc65 emits
 * a direct `jsr`, with the resident routines' cc65 fastcall ABI (args in A/X).
 * The order here, in svc.s, and in the cfg SYMBOLS block must all match.
 *
 * Each svc takes AT MOST ONE argument: the overlay and resident shell run on
 * separate cc65 C stacks (overlay sp in ZP $40-$5F, resident sp in $02-$1F), so
 * the last (register-passed) arg crosses fine but an earlier STACK-passed arg
 * arrives as garbage. A multi-value call needs a resident wrapper (see svc 12).
 */
#ifndef SVC_H
#define SVC_H

void svc_iec_set_fa(unsigned char dev);          /* svc 0  */
void svc_iec_set_sa(unsigned char sa);           /* svc 1  */
void svc_iec_setname(const char *name);          /* svc 2  */
void svc_iec_open(void);                          /* svc 3  */
unsigned char svc_iec_status(void);               /* svc 4  */
void svc_iec_chkin(void);                          /* svc 5  */
unsigned char svc_iec_getbyte(void);               /* svc 6  */
void svc_iec_close(void);                          /* svc 7  */
void svc_iec_clrchn(void);                          /* svc 8  */
void svc_fastload_set_device(unsigned char d);     /* svc 9  */
unsigned char svc_fastload_epyx_capable(void);     /* svc 10 */
void svc_fastload_epyx_install(void);              /* svc 11 */
unsigned char svc_fastload_epyx_send_dir_header(void);  /* svc 12: 0-arg "$" (see note) */
void svc_fastload_epyx_mark_unsupported(void);     /* svc 13 */
unsigned char svc_epyx_wait_ready(void);           /* svc 14 */
unsigned char svc_epyx_recv_byte(void);            /* svc 15 */

#endif /* SVC_H */
