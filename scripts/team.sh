#!/usr/bin/env bash
set -euo pipefail

# Usage: team.sh <team>
# Shows team members.

TEAM="${1:?Usage: team.sh <team> [--json] [--fix]}"
shift
OUTPUT_MODE=human
FIX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) OUTPUT_MODE=json ;;
    --fix) FIX=1 ;;
    *) echo "Usage: team.sh <team> [--json] [--fix]" >&2; exit 2 ;;
  esac
  shift
done
if [ "$FIX" -eq 1 ] && [ "$OUTPUT_MODE" = json ]; then
  echo "Usage: team.sh <team> [--json] [--fix] (--json and --fix cannot be combined)" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Reject team names that would escape teams/ as a path segment (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1

CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

if [ ! -f "$CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

# Placement starts from the recorded terminal and pane that peek/poke resolve.
# The team status layer then asks that terminal for its current location,
# activity, and independently observable identity fields. Recorded and observed
# facts stay separate so a missing pane or disabled visible naming cannot be
# presented as a match inferred from configuration.
#
# The source carries the errexit lift: a failure inside a sourced file fires this
# script's `set -e` on bash 3.2, and a roster must still list its members on a
# machine where the terminal layer is unavailable.
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
_agmsg_pl_rc=0; _agmsg_pl_e=0
case $- in *e*) _agmsg_pl_e=1 ;; esac
set +e
# shellcheck disable=SC1091
[ -r "$SCRIPT_DIR/lib/actas-lock.sh" ] && . "$SCRIPT_DIR/lib/actas-lock.sh" \
  && [ -r "$SCRIPT_DIR/lib/terminal-registry.sh" ] && . "$SCRIPT_DIR/lib/terminal-registry.sh"
_agmsg_pl_rc=$?
[ "$_agmsg_pl_e" = 1 ] && set -e
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/team-status.sh"

# Delivery belongs to a registration (type + project), not merely a member.
_member_delivery() {
  local type="$1" project="$2" out first rc=0
  out="$(bash "$SCRIPT_DIR/delivery.sh" status "$type" "$project" 2>/dev/null)" || rc=$?
  first="${out%%$'\n'*}"
  if [ "$rc" -ne 0 ] || [ -z "$first" ]; then
    printf 'unknown:delivery_status_rc_%s' "$rc"
    return 0
  fi
  case "$first" in mode:\ *) printf '%s' "${first#mode: }" ;; *) printf 'unknown:delivery_status_malformed' ;; esac
}

JSON_FIRST=1
_emit_row() {
  local member="$1" type="$2" project="$3" terminal="$4" pane="$5"
  local container="$6" activity="$7" delivery="$8"
  shift 8
  local label_cell="$1" label_expected="$2" label_actual="$3"
  local key_cell="$4" key_expected="$5" key_actual="$6"
  local session_cell="$7" session_expected="$8" session_actual="$9"
  shift 9
  local consistency="$1"
  if [ "$OUTPUT_MODE" = json ]; then
    [ "$JSON_FIRST" -eq 1 ] || printf ',\n'
    JSON_FIRST=0
    agmsg_team_render_json_row "$member" "$type" "$project" "$terminal" "$pane" \
      "$container" "$activity" "$delivery" \
      "$label_cell" "$label_expected" "$label_actual" \
      "$key_cell" "$key_expected" "$key_actual" \
      "$session_cell" "$session_expected" "$session_actual" "$consistency"
  else
    agmsg_team_render_human_row "$member" "$type" "$project" "$terminal" "$pane" \
      "$container" "$activity" "$delivery" \
      "$label_cell" "$key_cell" "$session_cell" "$consistency"
  fi
}

_emit_unknown_row() {
  local member="$1" type="$2" project="$3" terminal="$4" pane="$5"
  local container="$6" activity="$7" delivery="$8" reason="$9"
  local cell="unknown:$reason"
  _emit_row "$member" "$type" "$project" "$terminal" "$pane" "$container" \
    "$activity" "$delivery" \
    "$cell" "$cell" "$cell" "$cell" "$cell" "$cell" "$cell" "$cell" "$cell" unverified
}

_emit_fix_actions() {
  local actions="$1" field result reason
  while IFS="$(printf '\t')" read -r field result reason; do
    [ -n "$field" ] || continue
    printf '    fix.%s=%s(reason=%s)\n' "$field" "$result" "$reason"
  done <<EOF
$actions
EOF
}

_emit_unfixable_actions() {
  local reason="$1"
  [ "$FIX" -eq 1 ] || return 0
  _emit_fix_actions "$(printf 'pane_label\tskipped\t%s\nagent_key\tskipped\t%s\ncli_session\tskipped\t%s\n' "$reason" "$reason" "$reason")"
}

_member_status() {
  local team="$1" agent="$2" type="$3" project="$4" registered="$5"
  local rec ref terminal pane location container delivery identity
  local activity pane_label agent_key cli_session consistency reason
  local _actual_label _expected_label _actual_key _expected_key _actual_session _expected_session
  local fix_actions=""
  if [ "$registered" -eq 0 ]; then
    _emit_row "$agent" remote n/a:remote_registration \
      n/a:remote n/a:no_local_registration n/a:no_local_registration \
      n/a:no_local_registration n/a:no_local_registration \
      n/a:no_local_registration n/a:no_local_registration n/a:no_local_registration \
      n/a:no_local_registration n/a:no_local_registration n/a:no_local_registration \
      n/a:no_local_registration n/a:no_local_registration n/a:no_local_registration ok
    _emit_unfixable_actions no_local_registration
    return 0
  fi
  delivery="$(_member_delivery "$type" "$project")"
  if [ "$_agmsg_pl_rc" -ne 0 ] || ! declare -F agmsg_spawn_path >/dev/null 2>&1; then
    reason=terminal_support_not_loaded
    _emit_unknown_row "$agent" "$type" "$project" unknown "unknown:$reason" \
      "unknown:$reason" "unknown:$reason" "$delivery" "$reason"
    _emit_unfixable_actions "$reason"
    return 0
  fi
  rec="$(agmsg_spawn_path "$team" "$agent" 2>/dev/null)" || rec=""
  if [ -z "$rec" ] || [ ! -f "$rec" ]; then
    reason=no_placement_record
    _emit_unknown_row "$agent" "$type" "$project" unknown "unknown:$reason" \
      "unknown:$reason" "unknown:$reason" "$delivery" "$reason"
    _emit_unfixable_actions "$reason"
    return 0
  fi
  IFS="$(printf '\t')" read -r ref _ _ < "$rec" || true
  if [ -z "$ref" ]; then
    reason=empty_placement_record
    _emit_unknown_row "$agent" "$type" "$project" unknown "unknown:$reason" \
      "unknown:$reason" "unknown:$reason" "$delivery" "$reason"
    _emit_unfixable_actions "$reason"
    return 0
  fi
  terminal="$(agmsg_terminal_ref_terminal "$ref" 2>/dev/null)" || terminal=""
  pane="$(agmsg_terminal_ref_id "$ref" 2>/dev/null)" || pane=""
  if [ -z "$terminal" ] || [ -z "$pane" ]; then
    reason=invalid_placement_record
    _emit_unknown_row "$agent" "$type" "$project" unknown "unknown:$reason" \
      "unknown:$reason" "unknown:$reason" "$delivery" "$reason"
    _emit_unfixable_actions "$reason"
    return 0
  fi
  location="$(agmsg_team_location "$terminal" "$pane")"
  IFS="$(printf '\t')" read -r terminal pane container <<EOF
$location
EOF
  if agmsg_terminal_load "$terminal" >/dev/null 2>&1; then
    identity="$(agmsg_team_identity_loaded "$team" "$agent" "$type" "$terminal" "$pane")"
    IFS="$(printf '\t')" read -r activity _actual_label _expected_label _actual_key _expected_key _actual_session _expected_session pane_label agent_key cli_session consistency <<EOF
$identity
EOF
    if [ "$FIX" -eq 1 ]; then
      fix_actions="$(agmsg_team_fix_identity_loaded "$team" "$agent" "$type" "$terminal" "$pane" \
        "$pane_label" "$agent_key" "$cli_session")"
      identity="$(agmsg_team_identity_loaded "$team" "$agent" "$type" "$terminal" "$pane")"
      IFS="$(printf '\t')" read -r activity _actual_label _expected_label _actual_key _expected_key _actual_session _expected_session pane_label agent_key cli_session consistency <<EOF
$identity
EOF
    fi
  else
    reason=terminal_driver_load_failed
    activity="unknown:$reason"; pane_label="unknown:$reason"
    agent_key="unknown:$reason"; cli_session="unknown:$reason"
    _actual_label="$pane_label"; _expected_label="$team:$agent"
    _actual_key="$agent_key"; _expected_key="$agent_key"
    _actual_session="$cli_session"; _expected_session="$team-$agent"
    consistency=unverified
  fi
  _emit_row "$agent" "$type" "$project" "$terminal" "$pane" "$container" \
    "$activity" "$delivery" \
    "$pane_label" "$_expected_label" "$_actual_label" \
    "$agent_key" "$_expected_key" "$_actual_key" \
    "$cli_session" "$_expected_session" "$_actual_session" "$consistency"
  if [ "$FIX" -eq 1 ]; then
    if [ -n "$fix_actions" ]; then
      _emit_fix_actions "$fix_actions"
    else
      _emit_unfixable_actions terminal_driver_load_failed
    fi
  fi
}

if [ "$OUTPUT_MODE" = json ]; then
  printf '[\n'
else
  echo "Team: $TEAM"
  echo ""
fi

COUNT=0
LAST_NAME=""
# CONFIG_ESCAPED is spliced as a genuine SQL string literal below, NOT bound
# via `.param set`: the sqlite3 shell's dot-command tokenizer does not
# honour SQL '' escaping (unlike a real SQL statement's string literals), so
# `.param set :json '...'` silently mis-parses as soon as the config
# contains any single quote — e.g. an agent name like "al'ice" — and prints
# `.parameter`'s own usage help as if it were query output, with exit 0
# (#87 cluster; see resolve-project.sh's `resolve_team` for the same
# caveat).
CONFIG_ESCAPED=$(sed "s/'/''/g" "$CONFIG")
while IFS='	' read -r name type project registered; do
  if [ "$name" != "$LAST_NAME" ]; then
    COUNT=$((COUNT + 1))
    LAST_NAME="$name"
  fi
  if [ "${registered:-0}" -eq 0 ]; then
    # A member this machine has never registered locally: pulled with the team,
    # real, and correctly without registrations. Saying so beats printing an
    # empty type and a "?" project, which reads as damage.
    _member_status "$TEAM" "$name" "" "" 0
  else
    _member_status "$TEAM" "$name" "$type" "$project" 1
  fi
# tr -d '\r': sqlite3.exe on Windows emits CRLF rows; the trailing CR would make
# the `registrations` field "N\r" and trip the integer test in the loop (#130).
done < <(sqlite3 -separator '	' :memory: \
  "WITH agents AS (
     SELECT
       key AS name,
       CASE
         WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
         ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
       END AS registrations
     FROM json_each(json_extract('$CONFIG_ESCAPED', '\$.agents'))
   )
   SELECT
     name,
     COALESCE(json_extract(r.value, '\$.type'), ''),
     COALESCE(json_extract(r.value, '\$.project'), '?'),
     CASE WHEN r.value IS NULL THEN 0 ELSE 1 END
   -- LEFT JOIN, not a comma join: a member whose registrations array is empty
   -- produces no rows from json_each, so an inner join dropped them from the
   -- listing entirely and from the count with it. That is the normal state on
   -- a machine that pulled the team rather than joining it.
   FROM agents LEFT JOIN json_each(agents.registrations) AS r
   ORDER BY name, CAST(r.key AS INTEGER);" | tr -d '\r')

if [ "$OUTPUT_MODE" = json ]; then
  printf '\n]\n'
else
  echo ""
  echo "$COUNT member(s)"
fi
