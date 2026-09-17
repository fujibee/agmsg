#!/usr/bin/env bash
# Shell-quoting for values this tool prints back as part of a command someone
# is expected to run.

# agmsg_shq <value> -> the value as ONE shell argument, safely quoted.
#
# Wraps in single quotes and replaces each embedded ' with '\'' (close the
# quote, emit an escaped literal quote, reopen it) -- the standard POSIX
# technique. Unlike writing '$var' directly, this round-trips through the shell
# that later runs the result even when the value contains a single quote.
#
# This matters wherever the output is meant to be pasted and run: a team name
# is only validated against empty / '.' / '..' / '/' / '\' / a leading '-' /
# control characters (lib/validate.sh), so a single quote and a space are both
# legal in one. Naive quoting would end the quoted string early, and anything
# after it would be read by the pasting shell as syntax of its own.
agmsg_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
