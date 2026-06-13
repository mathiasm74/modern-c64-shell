/* overlay.h - tardis overlay commands (see overlay.c). */
#ifndef OVERLAY_H
#define OVERLAY_H

void cmd_about(int argc, char *argv[]);  /* overlay page 0 demo command */
void cmd_edit(int argc, char *argv[]);   /* nano-like editor (multi-page) */

/* Fetch (if needed) and run the files overlay (cat/less/cp/mv/rm); the fs.c
   thunks fill the mailbox at $02D0 first. */
void run_files_overlay(void);

/* Fetch (if needed) and run the dir overlay (dir/ls/pwd). */
void run_dir_overlay(void);

#endif /* OVERLAY_H */
