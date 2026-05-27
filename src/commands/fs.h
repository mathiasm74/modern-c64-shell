/* fs.h - filesystem commands over IEC (see fs.c). */
#ifndef FS_H
#define FS_H

void cmd_ls(int argc, char *argv[]);     /* list the directory              */
void cmd_load(int argc, char *argv[]);   /* read a PRG into memory          */
void cmd_run(int argc, char *argv[]);    /* run the loaded program          */
void cmd_device(int argc, char *argv[]); /* set the default IEC device      */
void cmd_rm(int argc, char *argv[]);     /* scratch a file                  */
void cmd_cp(int argc, char *argv[]);     /* copy a file                     */

#endif /* FS_H */
