/* mem.h - memory inspection commands (see mem.c). */
#ifndef MEM_H
#define MEM_H

void cmd_peek(int argc, char *argv[]);   /* peek $addr [count] - byte / hexdump */
void cmd_poke(int argc, char *argv[]);   /* poke $addr $val - write a byte */

#endif /* MEM_H */
