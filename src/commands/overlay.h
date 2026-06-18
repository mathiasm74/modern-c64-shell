/* overlay.h - tardis overlay commands (see overlay.c). */
#ifndef OVERLAY_H
#define OVERLAY_H

void cmd_about(int argc, char *argv[]);  /* the about screen (multi-page overlay) */
void cmd_edit(int argc, char *argv[]);   /* nano-like editor (multi-page) */

/* Fetch (if needed) and run the files overlay; thunks fill the mailbox at
   $02D0 first. */
void run_files_overlay(void);

/* Fill the files-overlay mailbox (cmd id, default device, two <=16-char args)
   and run it. Shared by the resident command thunks (fs.c / mem.c). */
void files_run(unsigned char cmd, const char *a1, const char *a2);

/* Fetch (if needed) and run the dir overlay (dir/ls/pwd). */
void run_dir_overlay(void);

#endif /* OVERLAY_H */
