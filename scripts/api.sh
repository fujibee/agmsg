#!/usr/bin/env bash
set -euo pipefail

# api.sh — a JSON-emitting entry point for non-bash consumers
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
# Shaped like a REST contract on purpose — verb + resource words. Lifecycle
# writes take a typed JSON object on stdin and go through the public storage
# facade; callers never need the SQLite path or a private schema.
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
#   api.sh get teams <team> capabilities
#   api.sh get teams <team> lifecycle [filters]
#   api.sh post teams <team> messages       # typed JSON on stdin
#   api.sh post teams <team> fetch          # typed JSON on stdin
#   api.sh post teams <team> acknowledgements # typed JSON on stdin
#   api.sh post teams <team> registrations # atomic work record + launch outbox
#   api.sh post teams <team> work-events    # typed JSON on stdin
#   api.sh post teams <team> outbox-claims|outbox-completions|outbox-retries
#
# Record output is JSONL — one JSON object per line, UTF-8, no pretty-printing.
# Outbox completion/retry are control operations and print `ok`. Every id
# (message ids included) is a JSON string, never a bare number — ids are opaque
# per the driver interface spec, and today's sqlite integer ids are no exception.

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
      -- Skip the copy the event log already carries. Every message is written
      -- to both tables so external readers of the legacy one keep working
      -- (#689); without this every message is returned twice, once under its
      -- event id and once under the legacy rowid.
      WHERE NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.legacy_id = messages.id)
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

get_lifecycle() {
  local team="$1"
  shift
  storage_lifecycle_history "$team" "$@"
}

get_active() {
  local team="$1"
  shift
  storage_lifecycle_active "$team" "$@"
}

# Read and validate one typed request without putting the whole JSON document
# in a SQL command. readfile() also preserves multiline message bodies exactly.
_api_request_open() {
  API_REQUEST_FILE="$(mktemp "${TMPDIR:-/tmp}/agmsg-api.XXXXXX")"
  trap '_api_request_close' EXIT HUP INT TERM
  cat >"$API_REQUEST_FILE"
  local path_sql
  path_sql="$(agmsg_sql_readfile_path "$API_REQUEST_FILE")"
  if [ "$(agmsg_sqlite_mem "SELECT json_valid(CAST(readfile('$path_sql') AS TEXT)) AND json_type(CAST(readfile('$path_sql') AS TEXT))='object';")" != 1 ]; then
    echo "agmsg: invalid_request: expected one JSON object on stdin" >&2
    return 2
  fi
}

_api_request_close() {
  [ -z "${API_REQUEST_FILE:-}" ] || rm -f "$API_REQUEST_FILE"
  API_REQUEST_FILE=""
}

_api_request_field() {
  local key="$1" required="${2:-required}" expected_type="${3:-text}" path_sql value actual_type
  path_sql="$(agmsg_sql_readfile_path "$API_REQUEST_FILE")"
  actual_type="$(agmsg_sqlite_mem "SELECT COALESCE(json_type(CAST(readfile('$path_sql') AS TEXT), '\$.$key'),'');")"
  if [ -z "$actual_type" ] || [ "$actual_type" = null ]; then
    if [ "$required" != required ]; then
      API_REQUEST_VALUE=""
      return 0
    fi
    echo "agmsg: invalid_request: missing '$key'" >&2
    return 2
  fi
  if [ "$actual_type" != "$expected_type" ]; then
    echo "agmsg: invalid_request: field '$key' must be $expected_type" >&2
    return 2
  fi
  if [ "$expected_type" = text ] && [ "$(agmsg_sqlite_mem "SELECT instr(json_extract(CAST(readfile('$path_sql') AS TEXT), '\$.$key'), char(0)) > 0;")" = 1 ]; then
    echo "agmsg: invalid_request: field '$key' contains U+0000" >&2
    return 2
  fi
  value="$(agmsg_sqlite_mem "SELECT json_extract(CAST(readfile('$path_sql') AS TEXT), '\$.$key') || '__AGMSG_FIELD_END__';")"
  API_REQUEST_VALUE="${value%__AGMSG_FIELD_END__}"
}

_api_request_assign() {
  local destination="$1"
  shift
  _api_request_field "$@" || return
  printf -v "$destination" '%s' "$API_REQUEST_VALUE"
}

_api_require_nonempty() {
  local key="$1" value="$2"
  [ -n "$value" ] || {
    echo "agmsg: invalid_request: field '$key' must not be empty" >&2
    return 2
  }
}

post_messages() {
  local team="$1" from to kind operation_key wake_target body
  _api_request_open || return
  _api_request_assign from from || return
  _api_request_assign to to || return
  _api_request_assign kind kind || return
  _api_request_assign operation_key operation_key || return
  _api_request_assign wake_target wake_target || return
  _api_request_assign body body || return
  _api_require_nonempty from "$from" || return
  _api_require_nonempty to "$to" || return
  _api_require_nonempty kind "$kind" || return
  _api_require_nonempty operation_key "$operation_key" || return
  _api_require_nonempty wake_target "$wake_target" || return
  agmsg_validate_agent_name "$from" || return
  agmsg_validate_agent_name "$to" || return
  storage_operation_send "$team" "$from" "$to" "$kind" "$operation_key" "$wake_target" "$body"
}

post_fetch() {
  local team="$1" agent consumer lease_seconds
  _api_request_open || return
  _api_request_assign agent agent || return
  _api_request_assign consumer consumer || return
  _api_request_assign lease_seconds lease_seconds required integer || return
  _api_require_nonempty agent "$agent" || return
  _api_require_nonempty consumer "$consumer" || return
  agmsg_validate_agent_name "$agent" || return
  case "$lease_seconds" in ''|*[!0-9]*) echo "agmsg: invalid_request: lease_seconds must be a positive integer" >&2; return 2 ;; esac
  [ "$lease_seconds" -gt 0 ] || { echo "agmsg: invalid_request: lease_seconds must be a positive integer" >&2; return 2; }
  storage_operation_fetch "$team" "$agent" "$consumer" "$lease_seconds"
}

post_acknowledgements() {
  local team="$1" agent message_id operation_key consumer result cleanup_target reason
  _api_request_open || return
  _api_request_assign agent agent || return
  _api_request_assign message_id message_id || return
  _api_request_assign operation_key operation_key || return
  _api_request_assign consumer consumer || return
  _api_request_assign result result || return
  _api_request_assign cleanup_target cleanup_target || return
  _api_request_assign reason reason optional || return
  _api_require_nonempty agent "$agent" || return
  _api_require_nonempty message_id "$message_id" || return
  _api_require_nonempty operation_key "$operation_key" || return
  _api_require_nonempty consumer "$consumer" || return
  _api_require_nonempty result "$result" || return
  _api_require_nonempty cleanup_target "$cleanup_target" || return
  agmsg_validate_agent_name "$agent" || return
  storage_operation_ack "$team" "$agent" "$message_id" "$operation_key" "$consumer" "$result" "$cleanup_target" "$reason"
}

post_work_events() {
  local team="$1" work_key operation_key actor state result reason
  _api_request_open || return
  _api_request_assign work_key work_key || return
  _api_request_assign operation_key operation_key || return
  _api_request_assign actor actor || return
  _api_request_assign state state || return
  _api_request_assign result result optional || return
  _api_request_assign reason reason optional || return
  _api_require_nonempty work_key "$work_key" || return
  _api_require_nonempty operation_key "$operation_key" || return
  _api_require_nonempty actor "$actor" || return
  _api_require_nonempty state "$state" || return
  storage_work_event "$team" "$work_key" "$operation_key" "$actor" "$state" "$result" "$reason"
}

post_registrations() {
  local team="$1" work_key operation_key actor generation origin launch_target wake_target stall_deadline
  _api_request_open || return
  _api_request_assign work_key work_key || return
  _api_request_assign operation_key operation_key || return
  _api_request_assign actor actor || return
  _api_request_assign generation generation required integer || return
  _api_request_assign origin origin || return
  _api_request_assign launch_target launch_target || return
  _api_request_assign wake_target wake_target || return
  _api_request_assign stall_deadline stall_deadline required integer || return
  _api_require_nonempty work_key "$work_key" || return
  _api_require_nonempty operation_key "$operation_key" || return
  _api_require_nonempty actor "$actor" || return
  _api_require_nonempty origin "$origin" || return
  _api_require_nonempty launch_target "$launch_target" || return
  _api_require_nonempty wake_target "$wake_target" || return
  case "$generation:$stall_deadline" in
    *[!0-9:]*|:*|*:) echo "agmsg: invalid_request: generation and stall_deadline must be positive integers" >&2; return 2 ;;
  esac
  if [ "$generation" -le 0 ] || [ "$stall_deadline" -le 0 ]; then
    echo "agmsg: invalid_request: generation and stall_deadline must be positive integers" >&2
    return 2
  fi
  storage_work_register "$team" "$work_key" "$operation_key" "$actor" "$generation" \
    "$origin" "$launch_target" "$wake_target" "$stall_deadline"
}

post_outbox_claims() {
  local team="$1" owner lease_seconds
  _api_request_open || return
  _api_request_assign owner owner || return
  _api_request_assign lease_seconds lease_seconds required integer || return
  _api_require_nonempty owner "$owner" || return
  case "$lease_seconds" in ''|*[!0-9]*) echo "agmsg: invalid_request: lease_seconds must be a positive integer" >&2; return 2 ;; esac
  [ "$lease_seconds" -gt 0 ] || { echo "agmsg: invalid_request: lease_seconds must be a positive integer" >&2; return 2; }
  storage_outbox_claim "$team" "$owner" "$lease_seconds"
}

post_outbox_completions() {
  local team="$1" outbox_id owner
  _api_request_open || return
  _api_request_assign outbox_id outbox_id || return
  _api_request_assign owner owner || return
  _api_require_nonempty outbox_id "$outbox_id" || return
  _api_require_nonempty owner "$owner" || return
  storage_outbox_complete "$team" "$outbox_id" "$owner"
}

post_outbox_retries() {
  local team="$1" outbox_id owner delay_seconds error
  _api_request_open || return
  _api_request_assign outbox_id outbox_id || return
  _api_request_assign owner owner || return
  _api_request_assign delay_seconds delay_seconds required integer || return
  _api_request_assign error error || return
  _api_require_nonempty outbox_id "$outbox_id" || return
  _api_require_nonempty owner "$owner" || return
  _api_require_nonempty error "$error" || return
  case "$delay_seconds" in ''|*[!0-9]*) echo "agmsg: invalid_request: delay_seconds must be a non-negative integer" >&2; return 2 ;; esac
  storage_outbox_retry "$team" "$outbox_id" "$owner" "$delay_seconds" "$error"
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
      local sub="${1:?Usage: api.sh get teams <team> store|members|messages|capabilities|lifecycle|active ...}"
      shift
      case "$sub" in
        members) get_members "$team" ;;
        messages) get_messages "$team" "$@" ;;
        store) get_store "$team" ;;
        capabilities) storage_capabilities "$team" ;;
        lifecycle) get_lifecycle "$team" "$@" ;;
        active) get_active "$team" "$@" ;;
        *) echo "Unknown resource: teams $team $sub" >&2; exit 1 ;;
      esac
      ;;
    *) echo "Unknown resource: $resource" >&2; exit 1 ;;
  esac
}

route_post() {
  local resource="${1:?Usage: api.sh post teams <team> messages|fetch|acknowledgements|registrations|work-events|outbox-claims|outbox-completions|outbox-retries}"
  shift
  [ "$resource" = teams ] || { echo "Unknown resource: $resource" >&2; exit 1; }
  local team="${1:?Usage: api.sh post teams <team> messages|fetch|acknowledgements|registrations|work-events|outbox-claims|outbox-completions|outbox-retries}"
  agmsg_validate_team_name "$team" || exit 1
  shift
  local sub="${1:?Usage: api.sh post teams <team> messages|fetch|acknowledgements|registrations|work-events|outbox-claims|outbox-completions|outbox-retries}"
  shift
  [ $# -eq 0 ] || { echo "Unknown option: $1" >&2; exit 1; }
  case "$sub" in
    messages) post_messages "$team" ;;
    fetch) post_fetch "$team" ;;
    acknowledgements) post_acknowledgements "$team" ;;
    registrations) post_registrations "$team" ;;
    work-events) post_work_events "$team" ;;
    outbox-claims) post_outbox_claims "$team" ;;
    outbox-completions) post_outbox_completions "$team" ;;
    outbox-retries) post_outbox_retries "$team" ;;
    *) echo "Unknown resource: teams $team $sub" >&2; exit 1 ;;
  esac
}

case "$VERB" in
  get) route_get "$@" ;;
  post) route_post "$@" ;;
  *)
    echo "Unknown verb: $VERB" >&2
    exit 1
    ;;
esac
