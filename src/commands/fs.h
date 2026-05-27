/* fs.h - filesystem commands over IEC (see fs.c). */
#ifndef FS_H
#define FS_H

void cmd_ls(int argc, char *argv[]);     /* list the directory of device 8 */
void cmd_load(int argc, char *argv[]);   /* read a PRG into memory          */
void cmd_run(int argc, char *argv[]);    /* jump to the loaded program      */

#endif /* FS_H */
