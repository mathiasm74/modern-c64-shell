/* fs.h - filesystem commands over IEC (see fs.c). */
#ifndef FS_H
#define FS_H

void cmd_run(int argc, char *argv[]);    /* run the loaded program          */
void cmd_sys(int argc, char *argv[]);    /* JSR into ML at <addr>, SYS-style */
void cmd_basic(int argc, char *argv[]);  /* swap to stock C64 ROMs (leave shell)*/
void cmd_font(int argc, char *argv[]);   /* live-switch the character ROM       */
void identify_boot_device(void);        /* main(): quiet boot identity fetch */ /* set the default IEC device      */

void print_device_prefix(void);          /* "<dev>[ <name>]" left of the prompt */

#endif /* FS_H */
