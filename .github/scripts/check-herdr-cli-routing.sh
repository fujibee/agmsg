#!/usr/bin/env bash
#
# Fail when scripts/drivers/terminals/herdr/ops.sh calls the `herdr` CLI directly
# from a function that is not on the named allowlist, or when an allowlisted
# function's count of direct calls moves in EITHER direction.
#
# WHY. A herdr pane id may be qualified by the socket of the instance that owns
# it (`<socket>:wN:pX`, #1055). Every call ABOUT that pane must reach that
# socket, which `_herdr_cli <id> ...` does by setting HERDR_SOCKET_PATH from the
# id. A call that bypasses `_herdr_cli` raises no error: it goes to whatever
# instance the ambient environment names, and a pane id is only unique inside
# one instance -- so the call lands on a different seat's live pane (measured
# 2026-09-11, the accident #1055 is about). One missed site is silent, and a
# review that reads twenty-one one-line edits will miss one. So this is
# counted by machine.
#
# HOW IT COUNTS. By CALL POSITION, not by text match: a line is a direct call
# only when `herdr <subcommand>` stands where a command stands -- at the start
# of a statement, or right after `$(`, `if`, `!`, `&&`, `||`, `|`, `then`,
# `else`, `do`, with any `VAR=value` assignment prefixes in between (a call
# that sets HERDR_SOCKET_PATH by hand is the bypass this exists to catch).
# Comment lines are skipped before matching, and `herdr:` inside a
# message string never has a subcommand word after it. (An earlier count of
# these calls by plain grep answered 55 where the true number is 34: comments
# and prose matched. That count is what this script must not repeat.)
#
# THE ALLOWLIST is `.github/herdr-cli-routing-allowlist`: one `<function> <count>`
# per line, naming the functions whose direct calls are instance-wide or
# deliberately ambient (listing every pane of an instance, spawning into the
# caller's own instance, describing the backend). A function not listed with a
# direct call fails; a listed function whose count went UP fails; a count that
# went DOWN fails too, and says to lower the entry -- an allowlist that is
# stale in the low direction lets the next addition hide inside the old number.
# `_herdr_cli` itself is the one function that must call `herdr` directly.

set -u
root="$(cd "$(dirname "$0")/../.." && pwd)"
ops="$root/scripts/drivers/terminals/herdr/ops.sh"
allow="$root/.github/herdr-cli-routing-allowlist"
[ -f "$ops" ]   || { echo "check-herdr-cli-routing: $ops not found" >&2; exit 2; }
[ -f "$allow" ] || { echo "check-herdr-cli-routing: $allow not found" >&2; exit 2; }

# function -> number of direct `herdr <subcommand>` calls at command position
counts="$(awk '
  /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { fn=$0; sub(/\(\).*/,"",fn); next }
  /^[[:space:]]*#/ { next }
  fn != "" {
    line=$0
    # strip a trailing comment that begins after whitespace
    sub(/[[:space:]]#.*$/,"",line)
    n=0
    # a command boundary, then optional spaces, then `herdr <word>`
    # An assignment prefix (VAR=value ...) before the word is still a command
    # position: `HERDR_SOCKET_PATH="$sock" herdr pane list` is exactly the form a
    # bypass of _herdr_cli takes, and it must be counted, not hidden by the prefix.
    while (match(line, /(^|\$\(|[;|&(]|[[:space:]](if|then|else|do|!)[[:space:]])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=("[^"]*"|[^[:space:]"]*)[[:space:]]+)*herdr[[:space:]]+[a-z][a-z-]*/)) {
      n++
      line=substr(line, RSTART+RLENGTH)
    }
    if (n) c[fn]+=n
  }
  END { for (f in c) printf "%s %d\n", f, c[f] }' "$ops" | sort)"

status=0
# every function with direct calls must be listed with exactly that count
while read -r fn n; do
  [ -n "$fn" ] || continue
  want="$(awk -v f="$fn" '$1==f {print $2}' "$allow")"
  if [ -z "$want" ]; then
    printf '  %s calls herdr directly %s time(s) and is not on the allowlist: route it through _herdr_cli <id>, or add "%s %s" to %s with a reason in the commit\n' "$fn" "$n" "$fn" "$n" "${allow#"$root/"}"
    status=1
  elif [ "$n" -gt "$want" ]; then
    printf '  %s: %s direct herdr calls, allowlist says %s -- ABOVE: a new direct call; route it through _herdr_cli <id> or raise the entry deliberately\n' "$fn" "$n" "$want"
    status=1
  elif [ "$n" -lt "$want" ]; then
    printf '  %s: %s direct herdr calls, allowlist says %s -- BELOW: lower the entry, or the next addition hides inside the old number\n' "$fn" "$n" "$want"
    status=1
  fi
done <<< "$counts"
# every listed function must still exist with a nonzero count
while read -r fn want; do
  case "$fn" in ''|'#'*) continue ;; esac
  if ! printf '%s\n' "$counts" | grep -q "^$fn "; then
    printf '  %s is on the allowlist with %s but makes no direct herdr call now -- remove the entry\n' "$fn" "$want"
    status=1
  fi
done < "$allow"

total="$(printf '%s\n' "$counts" | awk '{s+=$2} END {print s+0}')"
if [ "$status" -eq 0 ]; then
  echo "check-herdr-cli-routing: $total direct herdr calls, all on the allowlist at their listed counts."
else
  echo "check-herdr-cli-routing: FAILED (direct herdr calls outside _herdr_cli must be listed by name and count)."
fi
exit "$status"
