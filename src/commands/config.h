/* config.h - appearance commands: colors (see config.c). */
#ifndef CONFIG_H
#define CONFIG_H

void cmd_border(int argc, char *argv[]); /* border  <0-15>            */
void cmd_bg(int argc, char *argv[]);     /* bg      <0-15> background */
void cmd_text(int argc, char *argv[]);   /* text    <0-15> text color */

#endif /* CONFIG_H */
