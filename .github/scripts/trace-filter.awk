# Reduce a `strace -f` stream to the distinct paths a process tree looked at.
#
#   strace -f -qq -e trace=... -o '| awk -v T=<test> -f trace-filter.awk' cmd
#
# Prints "<T>\tF|D\t<path>" once per distinct path. D marks a path opened as a
# directory (a glob or a listing), F anything else (open, exec, stat, access).
# A path that does not exist is kept: a test that probes for a file depends on
# that file's absence just as much as on its content.
{
  line = $0
  if (match(line, /"[^"]*"/) == 0) next
  p = substr(line, RSTART + 1, RLENGTH - 2)
  if (p == "" || substr(p, 1, 1) == "?") next
  kind = (index(line, "O_DIRECTORY") > 0) ? "D" : "F"
  k = kind SUBSEP p
  if (k in seen) next
  seen[k] = 1
  printf "%s\t%s\t%s\n", T, kind, p
}
