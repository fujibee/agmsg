#!/usr/bin/env bash
# placement-report.sh -- say out loud when a seat's pane was not recorded.
#
# agmsg_terminal_name_self_safe records where a seat lives, and every refusal it
# can make (another seat already holds the pane, the pane cannot be identified,
# the record cannot be written) goes to stderr and returns 0 so that actas is
# never stopped by it. Callers throw that stderr away with `|| true`, or the
# skill never shows it, and the seat is told it is connected while peek/poke/
# despawn cannot find it. This wrapper keeps the same non-failing behaviour and
# adds one stdout line a caller's output can carry:
#
#   placement=unrecorded team=<team> reason=<one line>
#
# Nothing is printed when the pane was named or recorded, or when the terminal
# has nothing to record (plain). Never changes the exit status of the caller.
#
#   agmsg_placement_report <team> <name-args...>   (arguments of
#                                  agmsg_terminal_name_self_safe, unchanged)

agmsg_placement_report() {
  local team="${2:-}" errf="" rc=0 text=""
  declare -F agmsg_terminal_name_self_safe >/dev/null 2>&1 || return 0
  errf="$(mktemp "${TMPDIR:-/tmp}/agmsg-placement.XXXXXX" 2>/dev/null)" || errf=""
  if [ -n "$errf" ]; then
    agmsg_terminal_name_self_safe "$@" 2>"$errf" || rc=$?
    text="$(cat "$errf" 2>/dev/null || true)"
    rm -f "$errf"
    # What the callee said is still said, on stderr, as before.
    [ -z "$text" ] || printf '%s\n' "$text" >&2
  else
    agmsg_terminal_name_self_safe "$@" || rc=$?
  fi
  case "$text" in
    *"did not name or record"*|*"could not name"*|*"could not write"*|*"cannot record"*|*"cannot identify"*|*"could not be proven"*|*"no pane to name"*) ;;
    *) [ "$rc" -ne 0 ] || return 0 ;;
  esac
  # one line, no '=' or control characters that would break key=value parsing
  text="$(printf '%s' "$text" | tr '\n\t' '  ' | sed -e 's/ *(#[0-9][^)]*)\.*//g' -e 's/  */ /g' | cut -c1-400)"
  printf 'placement=unrecorded team=%s reason=%s\n' "$team" "${text:-naming_failed_rc_$rc}"
  return 0
}
