#!/usr/bin/env bash
set -euo pipefail

# terminal-nudge.sh — agmsgd's own entry point for the terminal-poke channel:
# the delivery path for a type with no native channel of its own (nudged
# through its pane instead). Resolves the seat's placement exactly the way
# poke.sh does, checks the driver's own readiness op first, and only then
# calls poke.sh itself to do the actual typing -- this script adds the
# "should we poke right now" gate, poke.sh keeps doing the poke.
#
# Usage:
#   terminal-nudge.sh <team> <agent> --body-file <path>
#   terminal-nudge.sh <team> <agent> --body -        # body read from stdin
#
# Prints exactly one line to stdout: "state=<state> reason=<reason>". Never
# prints the body. <state> is one of:
#   notified                         poke.sh delivered it (its exit 0)
#   not_ready:<reason>                driver says the seat is mid-turn/blocked
#   unknown:<reason>                  driver could not answer either way
#   no_pane                           no placement record for this seat
#   pane_gone                         record exists but did not resolve to a
#                                     loadable terminal + pane id
#   busy                             poke.sh's own retry budget was exhausted
#                                     on a changing input box (its exit 14)
#   box_not_found                    poke.sh could not locate the input box
#                                     (its exit 15)
#   unreachable                      poke.sh's driver call returned 10
#   pane_cannot_receive              poke.sh's driver call returned 12
#   unsupported                      poke.sh's driver has no poke path (13)
#   error:<rc>                       any other poke.sh exit code

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # required by actas-lock.sh
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/actas-lock.sh"         # agmsg_spawn_path
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/terminal-registry.sh"  # record scheme + driver load
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/type-registry.sh"      # agmsg_type_get
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/resolve-project.sh"    # agmsg_registered_type (#1391)

die_usage() {
  echo "terminal-nudge: $1" >&2
  echo "usage: terminal-nudge.sh <team> <agent> (--body-file <path> | --body -)" >&2
  exit 2
}

report() {   # <state> [reason]
  if [ -n "${2:-}" ]; then
    printf 'state=%s reason=%s\n' "$1" "$2"
  else
    printf 'state=%s reason=\n' "$1"
  fi
}

TEAM="${1:-}"; AGENT="${2:-}"
[ -n "$TEAM" ] && [ -n "$AGENT" ] || die_usage "team and agent are required"
shift 2

BODY_FILE=""
BODY_FILE_IS_TEMP=false
case "${1:-}" in
  --body-file)
    [ $# -eq 2 ] || die_usage "--body-file takes exactly one path"
    [ -r "${2:-}" ] || die_usage "cannot read body file: ${2:-<missing>}"
    BODY_FILE="$2"
    ;;
  --body)
    [ $# -eq 2 ] && [ "${2:-}" = "-" ] || die_usage "--body accepts only '-' (read stdin)"
    BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/agmsg-terminal-nudge.XXXXXX")" || die_usage "could not create a temp file for the body"
    BODY_FILE_IS_TEMP=true
    cat > "$BODY_FILE"
    ;;
  *)
    die_usage "the body must be --body-file <path> or --body -"
    ;;
esac
cleanup_body() { [ "$BODY_FILE_IS_TEMP" = true ] && rm -f "$BODY_FILE" 2>/dev/null; return 0; }
trap cleanup_body EXIT

# Same placement resolution as poke.sh, in the same order (#1391's roster
# override included) -- kept as its own copy rather than a shared function:
# poke.sh is a public entry point with its own stability contract, and this
# script's failure reporting (one short state= line, never poke.sh's
# human-readable stderr) is deliberately different shaped.
REC="$(agmsg_spawn_path "$TEAM" "$AGENT")"
if [ ! -f "$REC" ]; then
  report no_pane
  exit 0
fi

IFS=$'\t' read -r REF _PROJ TYPE _FENCE < "$REC" || true
if [ -z "$REF" ]; then
  report pane_gone "placement_record_no_id"
  exit 0
fi

ROSTER_TYPE="$(agmsg_registered_type "$TEAM" "$AGENT" 2>/dev/null || true)"
if [ -n "$ROSTER_TYPE" ] && [ "$ROSTER_TYPE" != "$TYPE" ]; then
  TYPE="$ROSTER_TYPE"
fi

TERMINAL=""; BARE_ID=""
TERMINAL="$(agmsg_terminal_ref_terminal "$REF")" || TERMINAL=""
BARE_ID="$(agmsg_terminal_ref_id "$REF")" || BARE_ID=""
if [ -z "$TERMINAL" ] || [ -z "$BARE_ID" ]; then
  report pane_gone "placement_ref_unresolvable"
  exit 0
fi

if ! agmsg_terminal_load "$TERMINAL" 2>/dev/null; then
  report pane_gone "driver_load_failed"
  exit 0
fi

# Readiness gate, when the loaded driver has one (same op and calling
# convention self-write.sh's _sw_cell_session uses). herdr: idle|done|working
# is ready, blocked (and a few other states) is not. tmux: whether the
# type's expected CLI is the pane's foreground process is ready/not_ready --
# a different question from herdr's (it says nothing about idle vs working
# vs blocked), but either way a not_ready/unknown answer here means nothing
# is typed. tmux's own "someone is actively typing right now" safety net is
# the input-box double-snapshot check poke.sh already does via
# agmsg_safe_poke, not this gate. A driver with no readiness op at all
# (declare -F finds none) adds no gate here -- poke.sh's own checks are all
# such a driver gets.
CLI="$(agmsg_type_get "$TYPE" cli)"
if declare -F terminal_team_input_ready >/dev/null 2>&1; then
  READY_RC=0
  READY_OUT="$(terminal_team_input_ready "$BARE_ID" "$CLI" 2>/dev/null)" || READY_RC=$?
  case "$READY_RC" in
    0) : ;;
    1) report "not_ready:${READY_OUT#not_ready:}"; exit 0 ;;
    *) report "unknown:${READY_OUT#unknown:}"; exit 0 ;;
  esac
fi

POKE_RC=0
"$SCRIPT_DIR/poke.sh" "$TEAM" "$AGENT" --body-file "$BODY_FILE" --retries 2 --retry-delay 2 --backoff exponential \
  >/dev/null 2>/dev/null || POKE_RC=$?

case "$POKE_RC" in
  0)  report notified ;;
  14) report busy ;;
  15) report box_not_found ;;
  10) report unreachable ;;
  12) report pane_cannot_receive ;;
  13) report unsupported ;;
  *)  report "error:$POKE_RC" ;;
esac
