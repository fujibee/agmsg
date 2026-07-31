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
agmsg_storage_load
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"

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

# Where a team's messages physically live, and in what form.
#
# Reading the store directly is faster than going through this script, and
# several programs outside agmsg do exactly that. This resource exists so they
# stop HARDCODING the path: ask, then read what you were told. A team that moves
# to its own store (connecting does that) then costs those readers nothing,
# where a hardcoded path leaves them opening a file that still exists and has
# none of their data in it — the failure that prompted this.
#
# `driver` is not decoration. A jsonl store is an append-only log, not a
# database; a consumer that opens it with a SQLite client gets nonsense. Check
# it before reading, and treat an unfamiliar value as "do not read this".
get_store() {
  local team="$1" path driver partition exists
  path="$(agmsg_db_path "$team")" || return 1
  driver="$(agmsg_storage_driver)"
  partition="$(agmsg_driver_for_team partition "$team" shared)"
  # json(...) so the field is a JSON boolean; a bare 1/0 reads as a number and a
  # consumer testing `=== true` would silently take the wrong branch.
  if [ -e "$path" ]; then exists="json('true')"; else exists="json('false')"; fi
  agmsg_sqlite_mem "SELECT json_object(
    'team', '$(agmsg_sqlesc "$team")',
    'driver', '$(agmsg_sqlesc "$driver")',
    'partition', '$(agmsg_sqlesc "$partition")',
    'path', '$(agmsg_sqlesc "$path")',
    'exists', $exists
  );"
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
  # Non-numeric --limit would otherwise land straight in the SQL text below —
  # same guard history.sh uses for LIMIT. --before-id is an opaque message id
  # (event-log ids are UUIDs, not numeric — see below), so it is NOT
  # numeric-filtered; it is bound as an escaped SQL string literal instead.
  case "$limit" in ''|*[!0-9]*) limit=30 ;; esac

  local db; db="$(agmsg_db_path "$team")"
  if [ ! -f "$db" ]; then
    return 0 # no store yet — empty result, not an error
  fi
  # The events table is created lazily by the facade on first write, so a
  # pure-legacy store (init-db.sh ran, storage_send never called) may have
  # messages but no events table yet — the UNION below would fail to parse
  # without it. storage_init is idempotent (CREATE TABLE IF NOT EXISTS).
  storage_init "$team" >/dev/null

  local team_sql; team_sql="$(_agmsg_sqlesc "$team")"
  local where="team='$team_sql'"
  if [ -n "$agent" ]; then
    local agent_sql; agent_sql="$(_agmsg_sqlesc "$agent")"
    where="$where AND (from_agent='$agent_sql' OR to_agent='$agent_sql')"
  fi
  local before_clause=""
  if [ -n "$before_id" ]; then
    local before_id_sql; before_id_sql="$(_agmsg_sqlesc "$before_id")"
    # Anchor pagination on the target row's own position (ord, see below),
    # not on comparing id values directly: a legacy row's id and an
    # event-log row's id are not from the same counter, so "id < before_id"
    # only makes sense within a single source. A before_id that matches no
    # row (bad cursor, or a compacted-away message) makes the subquery NULL,
    # so the whole clause is false — an empty page, not an error.
    before_clause="AND ord < (SELECT ord FROM combined WHERE id='$before_id_sql')"
  fi

  # Inner query takes the most recent `limit` by ord DESC, outer re-sorts
  # ASC — oldest-first output, same ordering contract §2.1 of the driver
  # spec requires of storage_history.
  # Reads BOTH the event log (where storage_send now writes) and the legacy
  # messages table (pre-flip installs), mirroring storage_history's UNION —
  # without it, any message sent after the storage flip would be invisible
  # here. `ord` is each source's own native monotonic counter (events.seq /
  # messages.id), used only to order rows and anchor before-id pagination;
  # it is never compared across sources.
  # id is exposed as TEXT: the driver-interface spec treats every message id
  # as opaque — a legacy sqlite integer id is a decimal STRING (not a JSON
  # number), same as an event-log UUID, so a consumer parsing id as a string
  # today needs no change as drivers evolve.
  agmsg_sqlite "$db" "
    WITH combined AS (
      SELECT id, team, from_agent, to_agent, body, at AS created_at, seq AS ord
      FROM events WHERE type='message_sent'
      UNION ALL
      SELECT CAST(id AS TEXT) AS id, team, from_agent, to_agent, body, created_at, id AS ord
      FROM messages
    )
    SELECT json_object(
      'type', 'message_sent',
      'id', id,
      'team', team,
      'from', from_agent,
      'to', to_agent,
      'body', body,
      'at', created_at
    ) FROM (
      SELECT * FROM combined WHERE $where $before_clause ORDER BY ord DESC LIMIT $limit
    ) ORDER BY ord ASC;
  "
}

route_get() {
  local resource="${1:?Usage: api.sh get teams [<team> store|members|messages ...]}"
  shift
  case "$resource" in
    teams)
      if [ $# -eq 0 ]; then
        get_teams
        return
      fi
      local team="$1"
      # Validate before the value is used by the members filesystem path.
      agmsg_validate_team_name "$team" || exit 1
      shift
      local sub="${1:?Usage: api.sh get teams <team> members|messages ...}"
      shift
      case "$sub" in
        members) get_members "$team" ;;
        messages) get_messages "$team" "$@" ;;
        store) get_store "$team" ;;
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
