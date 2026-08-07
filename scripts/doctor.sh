#!/usr/bin/env bash
set -euo pipefail

# doctor.sh — "who holds what" for a (project, type) in one screen. #267/#605.
#
# Usage: doctor.sh <project_path> <agent_type> [--redacted]
#
# Read-only: never claims, releases, or removes a lock, pidfile, or
# registration. A stale lock or dead pidfile is reported, not cleaned up --
# #605's reporter was asked not to remove a lock by hand because it erases
# the evidence; a doctor that cleaned up would do the same thing to itself.
#
# Data sources are the existing helpers this project already has for each
# fact -- identities.sh for registrations, actas-lock.sh/instance-id.sh for
# lock ownership and liveness, delivery.sh for mode and watcher/bridge
# status. Nothing here recomputes a verdict those already reach; #605's
# diagnostic duplicated agmsg_instance_alive once and that duplication was
# exactly what review pushed back on.
#
# Exit codes:
#   0  no warnings
#   1  one or more warnings (see WARNINGS section)
#   2  usage or resolution error

_usage() {
  echo "Usage: doctor.sh <project_path> <agent_type> [--redacted]" >&2
}

# Scanned for --help before the positional args are required below: with
# ${1:?...} doing that job instead, `doctor.sh --help` alone reads --help as
# PROJECT, then dies on the missing TYPE with "Missing agent_type" (bash's own
# nounset message, exit 1) and never reaches a help branch at all.
for _arg in "${@:-}"; do
  case "$_arg" in
    -h|--help) _usage; exit 0 ;;
  esac
done
unset _arg

if [ "$#" -lt 2 ]; then
  _usage
  exit 2
fi

PROJECT="$1"
TYPE="$2"
shift 2

REDACTED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --redacted) REDACTED=1; shift ;;
    *) echo "doctor: unknown option: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/type-registry.sh"

# Rejected here, not left to delivery.sh/identities.sh to fail into: those
# don't error loudly on an unknown type, they just return empty/quiet, which
# is exactly the "warning text on screen, exit 0 underneath" shape that made
# this a blocking finding in review.
if ! agmsg_is_known_type "$TYPE"; then
  echo "doctor: unknown agent type: '$TYPE' (supported: $(agmsg_known_types | sort -u | paste -sd, - | sed 's/,/, /g'))" >&2
  exit 2
fi

PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"

# Whether this type already reports its own per-role runtime status (codex's
# _delivery.sh does, via the embedded delivery-status block above -- one
# "Codex bridge: team/agent ..." line per role). Everything else (currently
# claude-code, opencode) falls through to the default runtime status, which
# is a single project-wide count with no per-role breakdown, so those types
# get the watcher= field built below instead. Detected structurally (does
# the type's plug override the function) rather than hardcoding "codex", so
# a future type with its own per-role reporting is picked up automatically.
TYPE_HAS_ROLE_RUNTIME=0
TYPE_DELIVERY_PLUG="$SKILL_DIR/scripts/drivers/types/$TYPE/_delivery.sh"
if [ -f "$TYPE_DELIVERY_PLUG" ] && grep -q '^agmsg_delivery_runtime_status()' "$TYPE_DELIVERY_PLUG" 2>/dev/null; then
  TYPE_HAS_ROLE_RUNTIME=1
fi

WARNINGS=""
_warn() { WARNINGS="${WARNINGS}$1"$'\n'; }

# --- redaction: consistent pseudonyms, not one-off masking -----------------
#
# A fixed team1/agent1 substitution (not a hash) so the same name reads the
# same way everywhere it appears in one run -- the #605 reporter hand-redacted
# their own report exactly this way (generic team/agent names, home-relative
# project path); this does the same substitution instead of leaving it to
# whoever pastes the output into a bug report.
# Sets _REDACT_OUT in the CALLER's shell rather than printf+$(...): a pair
# assigned inside a command substitution is a subshell, and the whole point
# here is a mutation (_R_TEAM_K/_R_TEAM_V growing) that has to survive past
# the call. role-session.sh's _agmsg_role_session_path_into hit this same
# shape first -- "a cache entry is only kept when the helper runs in the
# caller's own shell" applies just as much to a pseudonym table as a memo.
_R_TEAM_K=(); _R_TEAM_V=(); _R_AGENT_K=(); _R_AGENT_V=()
_redact_team() {
  [ "$REDACTED" = 1 ] || { _REDACT_OUT="$1"; return 0; }
  local i n=${#_R_TEAM_K[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_R_TEAM_K[$i]}" = "$1" ]; then _REDACT_OUT="${_R_TEAM_V[$i]}"; return 0; fi
  done
  _R_TEAM_K[$n]="$1"; _R_TEAM_V[$n]="team$((n + 1))"
  _REDACT_OUT="${_R_TEAM_V[$n]}"
}
_redact_agent() {
  [ "$REDACTED" = 1 ] || { _REDACT_OUT="$1"; return 0; }
  local i n=${#_R_AGENT_K[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_R_AGENT_K[$i]}" = "$1" ]; then _REDACT_OUT="${_R_AGENT_V[$i]}"; return 0; fi
  done
  _R_AGENT_K[$n]="$1"; _R_AGENT_V[$n]="agent$((n + 1))"
  _REDACT_OUT="${_R_AGENT_V[$n]}"
}
# Plain output shows the owner token IN FULL -- #605 was actually resolved by
# matching this exact value against a "codex-bridge: resumed thread <uuid>"
# line in a bridge log, and a shortened token can't be matched that way. This
# only shortens under --redacted, where the point is the opposite (safe to
# paste), and even then splits on the LAST "." rather than a fixed tail
# length: a fixed suffix cuts at a different point depending on how long the
# leading uuid/sid happens to be, while the part after the last "." is the
# pid every composite token carries -- consistently shaped, and still useful
# on its own (`ps -p <pid>`) even with the rest hidden. A bare token (no ".")
# has no such split point, so that case keeps the old fixed-tail form.
_redact_owner() {
  [ "$REDACTED" = 1 ] || { printf '%s' "$1"; return 0; }
  [ -n "$1" ] || return 0
  if agmsg_instance_is_composite "$1"; then
    printf '...%s' "${1##*.}"
  else
    printf '...%s' "${1: -6}"
  fi
}
# A path outside $HOME (a shared worktree, /Volumes/..., /Users/Shared/...)
# has no HOME-relative form to fall back to, and showing it raw would be the
# exact leak --redacted exists to prevent -- so that case gets a bare
# placeholder instead of the path. The HOME case keeps the more readable
# "~/..." form.
_redact_project() {
  [ "$REDACTED" = 1 ] || { printf '%s' "$1"; return 0; }
  case "$1" in
    "$HOME"*) printf '~%s' "${1#"$HOME"}" ;;
    *)        printf '<project>' ;;
  esac
}
# Literal (not glob, not regex) substring replace. A quoted portion of a
# case/parameter-expansion pattern matches literally regardless of what it
# contains, so this needs no escaping for team/agent names or paths that
# happen to hold *, ?, [, or other glob/regex metacharacters. Portable to
# bash 3.2 (macOS).
_replace_literal() {
  local rest="$1" needle="$2" repl="$3" out=""
  [ -n "$needle" ] || { printf '%s' "$rest"; return 0; }
  while true; do
    case "$rest" in
      *"$needle"*)
        out="$out${rest%%"$needle"*}$repl"
        rest="${rest#*"$needle"}"
        ;;
      *) break ;;
    esac
  done
  printf '%s%s' "$out" "$rest"
}
# Applies the SAME substitutions as the fields above to a block of TEXT this
# script did not format itself (delivery.sh's own output) -- --redacted's
# only promise is "safe to paste", so text quoted wholesale from elsewhere
# has to go through the same pseudonym table and $HOME masking as everything
# doctor.sh builds by hand, not get echoed as-is.
#
# No word boundaries: a team/agent name that also occurs as a substring
# elsewhere in the text (e.g. a team named "agmsg" inside a path like
# ~/.agents/skills/agmsg/run/...) gets replaced there too. Deliberately not
# fixed -- the failure direction is over-redaction, not a leak, which is the
# side --redacted is supposed to fail on.
_redact_text() {
  local text="$1" i n
  [ "$REDACTED" = 1 ] || { printf '%s' "$text"; return 0; }
  text="$(_replace_literal "$text" "$HOME" "~")"
  # A project outside $HOME survives the substitution above untouched (no
  # $HOME prefix to catch), and delivery.sh's own output names it directly
  # (its settings-hooks-file path is under it) -- so the exact resolved path
  # is masked here too, the same placeholder _redact_project uses for the
  # non-HOME case, not just doctor's own "project:" line.
  text="$(_replace_literal "$text" "$PROJECT" "<project>")"
  n=${#_R_TEAM_K[@]}
  for ((i = 0; i < n; i++)); do
    text="$(_replace_literal "$text" "${_R_TEAM_K[$i]}" "${_R_TEAM_V[$i]}")"
  done
  n=${#_R_AGENT_K[@]}
  for ((i = 0; i < n; i++)); do
    text="$(_replace_literal "$text" "${_R_AGENT_K[$i]}" "${_R_AGENT_V[$i]}")"
  done
  printf '%s' "$text"
}

# --- gather everything before printing anything ----------------------------
#
# Order matters here for one reason: redacting the embedded delivery-status
# block (below) needs the team/agent pseudonym table already built, and that
# table is only built by walking registrations. So registrations are walked
# first (silently, into REG_LINES) and the mode line is read before anything
# is echoed, even though "registrations" prints after "delivery status" on
# screen.
#
# Shelled out to the real CLI (not sourced): delivery.sh dispatches on argv at
# file scope, so sourcing it would run that dispatch. Reused verbatim (through
# _redact_text below) -- the type-specific per-role bridge liveness this
# project already has (codex's _delivery.sh) is not worth a second
# implementation here. Trade-off: MODE and the stale-pidfile warnings below
# are parsed out of this human-readable text, so if delivery.sh's wording
# changes, both go silent (no warning, not a wrong one) rather than erroring
# -- a duplicated implementation would drift instead of going quiet, which is
# worse. Flagged here so whoever next changes delivery.sh's status wording
# knows to check.
DELIVERY_STATUS=0
DELIVERY_OUTPUT="$(bash "$SCRIPT_DIR/delivery.sh" status "$TYPE" "$PROJECT" 2>&1)" || DELIVERY_STATUS=$?
MODE_LINE="$(printf '%s\n' "$DELIVERY_OUTPUT" | head -1)"
MODE="${MODE_LINE#mode: }"

PAIRS="$("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE")"
PAIR_COUNT="$(printf '%s\n' "$PAIRS" | grep -c . || true)"

REG_LINES=""
FIRST_TEAM="" FIRST_AGENT=""
if [ "$PAIR_COUNT" -gt 0 ]; then
  while IFS=$'\t' read -r team agent; do
    [ -z "$team" ] && continue
    [ -n "$FIRST_TEAM" ] || { FIRST_TEAM="$team"; FIRST_AGENT="$agent"; }

    _redact_team "$team"; dteam="$_REDACT_OUT"
    _redact_agent "$agent"; dagent="$_REDACT_OUT"
    owner="$(actas_lock_owner "$team" "$agent")"

    if [ -z "$owner" ]; then
      REG_LINES="${REG_LINES}$(printf '  %-22s lock=none' "$dteam/$dagent")"$'\n'
      continue
    fi

    if agmsg_instance_alive "$owner"; then
      alive_word="alive"
    else
      alive_word="STALE"
      _warn "stale lock: $dteam/$dagent (owner=$(_redact_owner "$owner"))"
    fi

    cc_note=""
    if agmsg_instance_is_composite "$owner"; then
      pid="${owner##*.}"
      if [ -f "$RUN_DIR/cc-instance.$pid" ]; then cc_note=" cc-instance=present"; else cc_note=" cc-instance=absent"; fi
    fi

    # Per-role watcher liveness -- only for types whose runtime status doesn't
    # already break this down per role (see TYPE_HAS_ROLE_RUNTIME above).
    # The pidfile watch.sh's SessionStart directive writes is keyed on the
    # SAME normalized instance id actas-claim.sh records as the lock owner
    # (both go through agmsg_normalize_instance_id on the same session id),
    # so the owner token IS the watcher's pidfile name -- no separate lookup
    # or correlation needed, and no liveness logic of its own: reuses
    # _agmsg_pid_alive_local, the same helper delivery.sh's own default
    # runtime status calls.
    watcher_note=""
    if [ "$TYPE_HAS_ROLE_RUNTIME" -eq 0 ]; then
      wpidfile="$RUN_DIR/watch.$owner.pid"
      if [ -f "$wpidfile" ]; then
        wpid="$(cat "$wpidfile" 2>/dev/null || true)"
        if [ -n "$wpid" ] && _agmsg_pid_alive_local "$wpid" 2>/dev/null; then
          watcher_note=" watcher=running"
        else
          watcher_note=" watcher=stale-pidfile"
        fi
      else
        watcher_note=" watcher=none"
        # Only when the lock itself is legitimately live: a stale lock having
        # no watcher is unremarkable (already covered by the warning above),
        # but an alive lock with no watcher means the role claims exclusivity
        # and isn't receiving -- the shape #605 and Alice/Bob both were.
        if [ "$alive_word" = "alive" ]; then
          _warn "actas lock held but no watcher: $dteam/$dagent (owner=$(_redact_owner "$owner"))"
        fi
      fi
    fi

    REG_LINES="${REG_LINES}$(printf '  %-22s lock=owner(%s)=%s%s%s' "$dteam/$dagent" "$alive_word" "$(_redact_owner "$owner")" "$cc_note" "$watcher_note")"$'\n'
  done <<< "$PAIRS"

  if [ "$PAIR_COUNT" -gt 1 ] && { [ "$MODE" = "turn" ] || [ "$MODE" = "both" ]; }; then
    _redact_team "$FIRST_TEAM"; first_dteam="$_REDACT_OUT"
    _redact_agent "$FIRST_AGENT"; first_dagent="$_REDACT_OUT"
    _warn "$PAIR_COUNT registrations for this (project, type) under turn-mode delivery -- only the first registered ($first_dteam/$first_dagent) receives Stop-hook delivery; the rest are silent under turn"
  fi
fi

# codex's per-role lines always carry a parenthetical reason (e.g. "stale
# pidfile (pid 123 not running)"); grepping for the "(" excludes the
# claude-code default's aggregate "N stale pidfiles" line, which is handled
# by the numeric check below instead and would otherwise false-positive here
# on its own plural (a literal prefix match of "stale pidfile").
if printf '%s\n' "$DELIVERY_OUTPUT" | grep -q "stale pidfile ("; then
  _warn "watcher/bridge pidfile present but process not running (see delivery status above)"
fi
STALE_COUNT="$(printf '%s\n' "$DELIVERY_OUTPUT" | sed -n 's/.*, \([0-9]*\) stale pidfiles*$/\1/p' | head -1)"
case "$STALE_COUNT" in ''|*[!0-9]*) STALE_COUNT=0 ;; esac
if [ "$STALE_COUNT" -gt 0 ]; then
  _warn "watcher/bridge pidfile present but process not running (see delivery status above)"
fi

# TYPE is already validated above, so this is not the "unknown type" case --
# some other failure inside delivery.sh status itself. Surfaced as a warning
# rather than swallowed: showing error text on screen while still reporting
# "no warnings." / exit 0 underneath would be a doctor that lies about its
# own read.
if [ "$DELIVERY_STATUS" -ne 0 ]; then
  _warn "delivery.sh status exited $DELIVERY_STATUS (see delivery status above)"
fi

# --- now print, in screen order -------------------------------------------
DISPLAY_PROJECT="$(_redact_project "$PROJECT")"
echo "project: $DISPLAY_PROJECT"
echo "type:    $TYPE"
echo

echo "$(_redact_text "$DELIVERY_OUTPUT")"
echo

echo "registrations ($PAIR_COUNT):"
if [ "$PAIR_COUNT" -eq 0 ]; then
  echo "  (none for this project/type)"
else
  printf '%s' "$REG_LINES"
fi
echo

if [ -n "$WARNINGS" ]; then
  echo "warnings:"
  printf '%s' "$WARNINGS" | sed 's/^/  - /'
  exit 1
fi
echo "no warnings."
exit 0
