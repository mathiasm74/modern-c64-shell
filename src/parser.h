/* parser.h - tokenize a command line into an argv-style argument vector. */
#ifndef PARSER_H
#define PARSER_H

#define MAX_ARGS 8              /* command name + up to 7 arguments */

struct command_line {
    int argc;
    char *argv[MAX_ARGS];       /* argv[0] is the command; rest are args */
};

/* Tokenize `line` in place, filling `cl`. Tokens are separated by runs of
   whitespace; a "double-quoted" run becomes a single token (spaces and all).
   The argv pointers point into `line`, whose token boundaries are overwritten
   with NULs -- so `cl` is only valid until `line` is reused. argc is 0 for an
   empty or all-whitespace line. At most MAX_ARGS tokens are kept; any extra
   are dropped. */
void parse_line(char *line, struct command_line *cl);

#endif /* PARSER_H */
