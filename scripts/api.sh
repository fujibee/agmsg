#!/usr/bin/env bash
set -euo pipefail

# api.sh — a read-only, JSON-emitting entry point for non-bash consumers
# (a GUI client, a bot in another language — anything that wants agmsg data
# without shelling out to sqlite3 directly). An ordinary core script, same
# standing as send.sh/history.sh/inbox.sh — NOT part of the storage-driver
# ABI (design/storage-axis, in progress as of this writing): that axis stays
# a sourced-function contract external drivers implement, and this stays a
# consumer of it. Queries the sqlite
# store directly for now; once the storage axis lands, the `messages`
# resource's query below is meant to become `storage_history`
# (driver-agnostic), unchanged on the outside — see the JSONL shape note there.
#
# Shaped like a REST contract on purpose — verb + resource words — so
# growing past read-only later (a `post teams <team> messages` == send,
# say) is a new verb branch, not a redesign. v1 only implements `get`.
#
# kubectl-style rather than gh-api-style: fixed resource nouns as separate
# positional args, not a "/teams/<team>/messages" path string. gh api's raw
# path makes sense for a generic HTTP passthrough (any path the real API
# supports just works); this has a small, fully-hardcoded set of routes, so
# a path string would only add parsing/construction overhead on both ends
# for no real flexibility gained.
#
# Usage:
#   api.sh get teams
#   api.sh get teams <team> members
#   api.sh get teams <team> messages [--agent <name>] [--limit N] [--before-id <id>]
#
# Output is always JSONL — one JSON object per line, UTF-8, no
# pretty-printing — for every resource, including `teams` (a uniform
# contract beats a special case a non-bash consumer has to remember).
# Nothing is written; this is read-only. Every id (message ids included) is
# a JSON string, never a bare number — ids are opaque per the driver
# interface spec, and today's sqlite integer ids are no exception.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

VERB="${1:?Usage: api.sh <verb> <resource> ... — e.g. api.sh get teams}"
shift

get_teams() {
  local teams_dir="$SCRIPT_DIR/../teams"
  [ -d "$teams_dir" ] || return 0
  local names=()
  for dir in "$teams_dir"/*/; do
    [ -f "${dir}config.json" ] || continue
    names+=("$(basename "$dir")")
  done
  [ ${#names[@]} -eq 0 ] && return 0
  # One sqlite call for all names (not one per team) — json_object() still
  # handles the JSON-escaping per name (a quote in a team name, say), it's
  # just batched into a single UNION ALL rather than N process spawns.
  local query="" name
  for name in "${names[@]}"; do
    local name_sql; name_sql="$(_agmsg_sqlesc "$name")"
    [ -n "$query" ] && query="$query UNION ALL "
    query="${query}SELECT '$name_sql' AS n"
  done
  agmsg_sqlite_mem "SELECT json_object('name', n) FROM ($query) ORDER BY n;"
}

get_members() {
  local team="$1"
  local config="$SCRIPT_DIR/../teams/$team/config.json"
  [ -f "$config" ] || return 0
  local path_sql; path_sql="$(agmsg_sql_readfile_path "$config")"
  # Table-alias the outer and inner json_each explicitly (a.key/a.value vs
  # r.value) — both produce a column literally named "value", and an
  # unqualified reference inside the correlated subquery silently resolves
  # to the wrong scope (returns empty, not an error) without the aliases.
  agmsg_sqlite_mem "
    WITH cfg AS (SELECT CAST(readfile('$path_sql') AS TEXT) AS json)
    SELECT json_object(
      'name', a.key,
      'types', (
        SELECT json_group_array(DISTINCT json_extract(r.value, '\$.type'))
        FROM json_each(json_extract(a.value, '\$.registrations')) AS r
      ),
      'project', (
        SELECT json_extract(r.value, '\$.project')
        FROM json_each(json_extract(a.value, '\$.registrations')) AS r
        LIMIT 1
      )
    )
    FROM cfg, json_each(json_extract(cfg.json, '\$.agents')) AS a
    ORDER BY a.key;
  "
}

get_messages() {
  local team="$1"
  shift
  local agent="" limit=30 before_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) agent="${2:?--agent needs a value}"; shift 2 ;;
      --limit) limit="${2:?--limit needs a value}"; shift 2 ;;
      --before-id) before_id="${2:?--before-id needs a value}"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done
  # Non-numeric values would otherwise land straight in the SQL text below —
  # same guard history.sh uses for LIMIT.
  case "$limit" in ''|*[!0-9]*) limit=30 ;; esac
  case "$before_id" in ''|*[!0-9]*) before_id="" ;; esac

  local db; db="$(agmsg_db_path)"
  if [ ! -f "$db" ]; then
    return 0 # no store yet — empty result, not an error
  fi

  local team_sql; team_sql="$(_agmsg_sqlesc "$team")"
  local where="team='$team_sql'"
  if [ -n "$agent" ]; then
    local agent_sql; agent_sql="$(_agmsg_sqlesc "$agent")"
    where="$where AND (from_agent='$agent_sql' OR to_agent='$agent_sql')"
  fi
  if [ -n "$before_id" ]; then
    where="$where AND id<$before_id"
  fi

  # Inner query takes the most recent `limit` by id DESC, outer re-sorts
  # ASC — oldest-first output, same ordering contract §2.1 of the driver
  # spec requires of storage_history, so a future swap to that function
  # doesn't change what this command prints.
  # id is CAST to TEXT: the driver-interface spec treats every message id as
  # opaque, and a legacy sqlite integer id is specifically passed through as
  # a decimal STRING (not a JSON number) so a future UUIDv7/Redis-stream-id
  # driver doesn't change this field's JSON type — a consumer parsing id as
  # a string today needs no change once that lands.
  agmsg_sqlite "$db" "
    SELECT json_object(
      'type', 'message_sent',
      'id', CAST(id AS TEXT),
      'team', team,
      'from', from_agent,
      'to', to_agent,
      'body', body,
      'at', created_at
    ) FROM (
      SELECT * FROM messages WHERE $where ORDER BY id DESC LIMIT $limit
    ) ORDER BY id ASC;
  "
}

route_get() {
  local resource="${1:?Usage: api.sh get teams [<team> members|messages ...]}"
  shift
  case "$resource" in
    teams)
      if [ $# -eq 0 ]; then
        get_teams
        return
      fi
      local team="$1"
      shift
      local sub="${1:?Usage: api.sh get teams <team> members|messages ...}"
      shift
      case "$sub" in
        members) get_members "$team" ;;
        messages) get_messages "$team" "$@" ;;
        *) echo "Unknown resource: teams $team $sub" >&2; exit 1 ;;
      esac
      ;;
    *) echo "Unknown resource: $resource" >&2; exit 1 ;;
  esac
}

case "$VERB" in
  get) route_get "$@" ;;
  *)
    echo "Unknown verb: $VERB (only 'get' is implemented — read-only for now)" >&2
    exit 1
    ;;
esac
