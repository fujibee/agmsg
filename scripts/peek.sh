#!/usr/bin/env bash
set -euo pipefail

# peek.sh — read one member, or summarize every local member in this project.
#
# Usage:
#   peek.sh <team> [<name> [--lines N]]
#
#   <team>     team the member is in
#   <name>     the member whose pane to read
#   --lines N  request scrollback depth N (passed unchanged to the tmux/herdr
#              backend)
#
# Read-only. The member's placement record (run/spawn.<team>__<name>, written
# at placement time) names the terminal and the pane id; that terminal's driver
# is loaded and terminal_peek prints the pane text verbatim. The terminal comes
# from the RECORD, never from this caller's environment — an exported
# AGMSG_TERMINAL_DRIVER must not make us read a herdr pane id as a tmux one
# (v1 scope ruling: the override applies to resolution, never to something
# already placed).
#
# A terminal without an addressable pane (plain) refuses with
# "unsupported: <why>" on stderr and a non-zero exit — never a silent 0.
#
# #1229 exception: a bare plain:- claude-code target has no pane AT ALL, but
# still has its own session transcript on disk -- a read-only, agent-native
# substitute for "recent state" (see _peek_native_transcript below). Its
# output leads with a marker line so a caller always knows this was a
# transcript read, never a screen read.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"          # agmsg_spawn_path
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/terminal-registry.sh"   # record scheme + driver load
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

die() { echo "peek: $*" >&2; exit 1; }

TEAM="${1:-}"
[ -n "$TEAM" ] || die "Usage: peek.sh <team> [<name> [--lines N]]"
shift

# #1229: a bare plain:- target has no pane, so terminal_peek for it can only
# ever return 13 (see plain/ops.sh's terminal_peek: id='-' is the first
# check, unconditional). For a claude-code target specifically, its own
# session transcript is a read-only, agent-native substitute for "recent
# state" -- resolved from the actas lock this session's OWNER actually
# holds (never guessed), never written to. Prints a marker line first so a
# caller can always tell a transcript read from a screen read; returns 1
# when no substitute is available (stale/no lock, dead owner, no transcript)
# so the caller falls back to the driver's own "unsupported" message.
_peek_native_transcript() {   # <team> <name> <project> <lines>
  local team="$1" name="$2" project="$3" lines="$4" rd kind owner bare content
  # The on-disk transcript layout is claude-code-internal, so the reader
  # lives in that type's own driver hook, never here (same reasoning as
  # boot-command.sh's resume-uuid gate). A hardcoded relative path, not the
  # generic type-registry lookup boot-command.sh uses: this function is
  # ALREADY only reached from the type == claude-code branch, so there is no
  # type to look up. Absent hook => cannot read => no substitute.
  if ! declare -F agmsg_transcript_tail >/dev/null 2>&1; then
    local hook="$SCRIPT_DIR/drivers/types/claude-code/_transcript-exists.sh"
    [ -f "$hook" ] || return 1
    # shellcheck disable=SC1090
    . "$hook"
    declare -F agmsg_transcript_tail >/dev/null 2>&1 || return 1
  fi
  rd="$(actas_lock_read "$team" "$name")"
  kind="${rd%%$'\t'*}"; owner="${rd#*$'\t'}"
  [ "$kind" = ok ] && [ -n "$owner" ] || return 1
  agmsg_instance_alive "$owner" || return 1
  bare="$(agmsg_instance_bare_sid "$owner")"
  content="$(agmsg_transcript_tail "$bare" "$project" "$lines")" || return 1
  [ -n "$content" ] || return 1
  printf 'AGMSG-NATIVE-RECORD: claude-code session transcript (no addressable pane; not a live screen)\n'
  printf '%s\n' "$content"
}

_peek_one() { # <team> <name> [lines]
  local team="$1" name="$2" lines="${3:-}" rec ref terminal bare_id proj type
  rec="$(agmsg_spawn_path "$team" "$name")"
  [ -f "$rec" ] || {
    echo "peek: no placement record for '$team/$name' — nothing here knows which pane is theirs (spawn writes it at launch; a hand-joined member gets one when a terminal-aware session names its pane)" >&2
    return 1
  }
  IFS=$'\t' read -r ref proj type _fence < "$rec" || true
  [ -n "$ref" ] || {
    echo "peek: placement record for '$team/$name' has no pane id — a record with no id is not a placement (a bug in whatever wrote it)" >&2
    return 1
  }
  terminal=""; bare_id=""
  terminal="$(agmsg_terminal_ref_terminal "$ref")" || terminal=""
  bare_id="$(agmsg_terminal_ref_id "$ref")" || bare_id=""
  [ -n "$terminal" ] && [ -n "$bare_id" ] || {
    echo "peek: placement record for '$team/$name' did not resolve to a terminal and pane id (ref: '$ref')" >&2
    return 1
  }
  agmsg_terminal_load "$terminal" || {
    echo "peek: cannot load terminal driver '$terminal' recorded for '$team/$name'" >&2
    return 1
  }
  if [ "$terminal" = plain ] && [ "$bare_id" = '-' ] && [ "$type" = claude-code ]; then
    # This id can only ever return 13 -- there is no success stream from it
    # to preserve byte-for-byte, so capturing its stderr here (unlike the
    # plain passthrough below) cannot corrupt a verbatim screen read that
    # does not exist for this case.
    local trc=0 terr=""
    terr="$(terminal_peek "$bare_id" 2>&1 >/dev/null)" || trc=$?
    if [ "$trc" -eq 13 ] && _peek_native_transcript "$team" "$name" "$proj" "${lines:-20}"; then
      return 0
    fi
    [ -z "$terr" ] || printf '%s\n' "$terr" >&2
    return "${trc:-1}"
  fi
  if [ -n "$lines" ]; then terminal_peek "$bare_id" --lines "$lines"; else terminal_peek "$bare_id"; fi
}

_last_line() { printf '%s\n' "$1" | tail -n 1 | cut -c 1-58; }
_sweep_row() { printf '%-11.11s  %-6.6s  %-16.16s  %-58.58s\n' "$1" "$2" "$3" "$4"; }

_classify_screen() {
  # Shell patterns inspect the complete value without a grep -q pipeline. With
  # pipefail, grep exiting early on a long screen can SIGPIPE printf and turn a
  # true match into a false pipeline status.
  case "$1" in
    *'Do you want to proceed'*) printf 'approval' ;;
    *'esc to interrupt'*|*'Worked for'*|*'Running'*) printf 'working' ;;
    *) printf 'idle' ;;
  esac
}

_team_rows() {
  local config="$SKILL_DIR/teams/$1/config.json" config_sql rows rc=0
  [ -r "$config" ] || { echo "peek: team config is unreadable: $1" >&2; return 10; }
  config_sql="$(agmsg_sql_readfile_path "$config")"
  rows="$(sqlite3 -separator $'\t' :memory: \
    "WITH agents AS (
       SELECT key AS name,
         CASE WHEN json_type(json_extract(value, '\$.registrations')) = 'array'
           THEN json_extract(value, '\$.registrations')
           ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
         END AS registrations
       FROM json_each(json_extract(readfile('$config_sql'), '\$.agents'))
     )
     SELECT name, COALESCE(json_extract(r.value, '\$.type'), ''),
       COALESCE(json_extract(r.value, '\$.project'), ''),
       CASE WHEN r.value IS NULL THEN 0 ELSE 1 END
     FROM agents LEFT JOIN json_each(agents.registrations) AS r
     ORDER BY name, CAST(r.key AS INTEGER);" 2>/dev/null | tr -d '\r')" || rc=$?
  [ "$rc" -eq 0 ] || { echo "peek: team roster query failed (rc $rc)" >&2; return 10; }
  printf '%s\n' "$rows"
}

_peek_team() {
  local team="$1" rows rows_rc=0 name type project registered resolved
  local rec ref pane screen state rc
  rows="$(_team_rows "$team")" || rows_rc=$?
  [ "$rows_rc" -eq 0 ] || return "$rows_rc"
  _sweep_row MEMBER PANE STATE LAST_LINE
  while IFS=$'\t' read -r name type project registered; do
    [ -n "$name" ] || continue
    if [ "${registered:-0}" -eq 0 ]; then
      _sweep_row "$name" - excluded:remote no_local_registration
      continue
    fi
    resolved="$(agmsg_resolve_project "$PWD" "$type" "$team")"
    if [ "$(agmsg_normalize_project_path "$resolved")" != "$(agmsg_normalize_project_path "$project")" ]; then
      _sweep_row "$name" - excluded:project "$project"
      continue
    fi
    rec="$(agmsg_spawn_path "$team" "$name")"
    if [ ! -f "$rec" ]; then
      _sweep_row "$name" - no_record no_placement_record
      continue
    fi
    IFS=$'\t' read -r ref _rec_project _rec_type _rec_fence < "$rec" || true
    pane="$(agmsg_terminal_ref_id "${ref:-}" 2>/dev/null)" || pane="?"
    screen=""; rc=0
    screen="$(_peek_one "$team" "$name" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      _sweep_row "$name" "$pane" "read_rc_$rc" "$(_last_line "$screen")"
      continue
    fi
    state="$(_classify_screen "$screen")"
    _sweep_row "$name" "$pane" "$state" "$(_last_line "$screen")"
  done <<EOF
$rows
EOF
}

if [ $# -eq 0 ]; then
  _peek_team "$TEAM"
  exit $?
fi

NAME="$1"
shift

PEEK_LINES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lines)
      PEEK_LINES="${2:-}"
      case "$PEEK_LINES" in
        ''|*[!0-9]*) die "--lines must be a whole number of lines" ;;
      esac
      shift 2
      ;;
    *) die "unknown option: $1" ;;
  esac
done

_peek_one "$TEAM" "$NAME" "$PEEK_LINES"
