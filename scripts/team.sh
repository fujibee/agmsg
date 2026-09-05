#!/usr/bin/env bash
set -euo pipefail

# Usage: team.sh <team>
# Shows team members.

TEAM="${1:?Usage: team.sh <team>}"

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

# Where each member's pane is, when we know. A pane with no name is invisible
# from inside agmsg -- the #1044 dogfood found one by reading the terminal's own
# JSON, because nothing here reported it -- and that is also why there was no way
# to assert the naming requirement. This column is what makes it checkable.
#
# What is printed is the PLACEMENT RECORD, which is a recorded fact: the terminal
# and the pane id that peek/poke resolve a member through. The visible label is
# NOT printed, because reading it back means asking the terminal and no read op
# for it exists; inferring it from the record would report a claim as an
# observation, and under AGMSG_TERMINAL_NAMING=off it would be wrong.
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
  local type="$1" project="$2" first rc=0
  first="$(bash "$SCRIPT_DIR/delivery.sh" status "$type" "$project" 2>/dev/null | head -1)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$first" ]; then
    printf 'unknown:delivery_status_rc_%s' "$rc"
    return 0
  fi
  case "$first" in mode:\ *) printf '%s' "${first#mode: }" ;; *) printf 'unknown:delivery_status_malformed' ;; esac
}

_member_status() {
  local team="$1" agent="$2" type="$3" project="$4" registered="$5"
  local rec ref terminal pane location container live delivery identity
  local activity pane_label agent_key cli_session consistency reason
  if [ "$registered" -eq 0 ]; then
    agmsg_team_render_human_row "$agent" remote n/a:remote_registration \
      n/a:remote n/a:no_local_registration n/a:no_local_registration \
      unknown:no_local_registration n/a:no_local_registration \
      n/a:no_local_registration n/a:no_local_registration \
      n/a:no_local_registration n/a:no_local_registration ok
    return 0
  fi
  delivery="$(_member_delivery "$type" "$project")"
  if [ "$_agmsg_pl_rc" -ne 0 ] || ! declare -F agmsg_spawn_path >/dev/null 2>&1; then
    reason=terminal_support_not_loaded
    agmsg_team_render_human_row "$agent" "$type" "$project" unknown "unknown:$reason" \
      "unknown:$reason" "unknown:$reason" "unknown:$reason" "$delivery" \
      "unknown:$reason" "unknown:$reason" "unknown:$reason" unverified
    return 0
  fi
  rec="$(agmsg_spawn_path "$team" "$agent" 2>/dev/null)" || rec=""
  if [ -z "$rec" ] || [ ! -f "$rec" ]; then
    reason=no_placement_record
    agmsg_team_render_human_row "$agent" "$type" "$project" unknown "unknown:$reason" \
      "unknown:$reason" "unknown:$reason" "unknown:$reason" "$delivery" \
      "unknown:$reason" "unknown:$reason" "unknown:$reason" unverified
    return 0
  fi
  IFS="$(printf '\t')" read -r ref _ _ < "$rec" || true
  if [ -z "$ref" ]; then
    reason=empty_placement_record
    agmsg_team_render_human_row "$agent" "$type" "$project" unknown "unknown:$reason" \
      "unknown:$reason" "unknown:$reason" "unknown:$reason" "$delivery" \
      "unknown:$reason" "unknown:$reason" "unknown:$reason" unverified
    return 0
  fi
  terminal="$(agmsg_terminal_ref_terminal "$ref" 2>/dev/null)" || terminal=""
  pane="$(agmsg_terminal_ref_id "$ref" 2>/dev/null)" || pane=""
  if [ -z "$terminal" ] || [ -z "$pane" ]; then
    reason=invalid_placement_record
    agmsg_team_render_human_row "$agent" "$type" "$project" unknown "unknown:$reason" \
      "unknown:$reason" "unknown:$reason" "unknown:$reason" "$delivery" \
      "unknown:$reason" "unknown:$reason" "unknown:$reason" unverified
    return 0
  fi
  location="$(agmsg_team_location "$terminal" "$pane")"
  IFS="$(printf '\t')" read -r terminal pane container live <<EOF
$location
EOF
  if [ "$live" = present ] && agmsg_terminal_load "$terminal" >/dev/null 2>&1; then
    identity="$(agmsg_team_identity_loaded "$team" "$agent" "$type" "$terminal" "$pane")"
    IFS="$(printf '\t')" read -r activity pane_label agent_key cli_session consistency <<EOF
$identity
EOF
  else
    reason="live_${live}"
    activity="unknown:$reason"; pane_label="unknown:$reason"
    agent_key="unknown:$reason"; cli_session="unknown:$reason"
    consistency=unverified
  fi
  agmsg_team_render_human_row "$agent" "$type" "$project" "$terminal" "$pane" \
    "$container" "$live" "$activity" "$delivery" "$pane_label" "$agent_key" \
    "$cli_session" "$consistency"
}

echo "Team: $TEAM"
echo ""

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

echo ""
echo "$COUNT member(s)"
