/* fs.h - filesystem commands over IEC (see fs.c). */
#ifndef FS_H
#define FS_H

void cmd_dir(int argc, char *argv[]);    /* full 1541-style directory       */
void cmd_ls(int argc, char *argv[]);     /* file names, colored by type     */
void cmd_pwd(int argc, char *argv[]);    /* print the disk name             */
void cmd_load(int argc, char *argv[]);   /* read a PRG into memory          */
void cmd_fload(int argc, char *argv[]);  /* experimental Epyx fast load      */
void cmd_run(int argc, char *argv[]);    /* run the loaded program          */
void cmd_runstock(int argc, char *argv[]); /* swap to stock ROMs, then run  */
void cmd_device(int argc, char *argv[]); /* set the default IEC device      */
void cmd_cd(int argc, char *argv[]);     /* drive-side change directory     */
void cmd_rm(int argc, char *argv[]);     /* scratch a file                  */
void cmd_mv(int argc, char *argv[]);     /* rename a file                   */
void cmd_cp(int argc, char *argv[]);     /* copy a file                     */
void cmd_save(int argc, char *argv[]);   /* write a memory range as a PRG   */
void cmd_status(int argc, char *argv[]); /* read the drive error channel    */
void cmd_cat(int argc, char *argv[]);    /* dump a file to the screen       */
void cmd_less(int argc, char *argv[]);   /* page a file                     */

#endif /* FS_H */
