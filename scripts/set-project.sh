#!/usr/bin/env bash
set -euo pipefail

# Usage: set-project.sh <team> <agent_id> <new_project> [--type <type>]
#
# Repoints an existing agent's registered project dir. join.sh only ever ADDS a
# registration (a re-join with a different project leaves the old one in place),
# so this is the only way to move an already-registered agent to a different
# directory without leave.sh dropping the member entirely.
#
# Without --type every registration the agent has in this team moves. With
# --type only that type's registrations move, leaving the agent's other types
# where they are.
#
# The path is taken as given (only spelling-normalized): callers here are
# deliberate — a human picking a directory in the app, or an agent told to move
# a role — so this does NOT run agmsg_resolve_project, same as spawn.sh's
# explicit --project. Nor does it create the directory; join.sh doesn't either,
# and the app's own agmsg_set_project does that before calling us.

TEAM="${1:?Usage: set-project.sh <team> <agent_id> <new_project> [--type <type>]}"
AGENT_ID="${2:?Missing agent_id}"
NEW_PROJECT="${3:?Missing new_project}"
shift 3

AGENT_TYPE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --type)
      AGENT_TYPE="${2:?Missing value for --type}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"

agmsg_validate_team_name "$TEAM" || exit 1
agmsg_validate_agent_name "$AGENT_ID" || exit 1

if [ -n "$AGENT_TYPE" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/type-registry.sh"
  if ! agmsg_is_known_type "$AGENT_TYPE"; then
    echo "Unknown agent type: '$AGENT_TYPE' (supported: $(agmsg_known_types | sort -u | paste -sd, - | sed 's/,/, /g'))" >&2
    exit 1
  fi
fi

NEW_PROJECT="$(agmsg_normalize_project_path "$NEW_PROJECT")"

TEAM_DIR="$TEAMS_DIR/$TEAM"
TEAM_CONFIG="$TEAM_DIR/config.json"
if [ ! -f "$TEAM_CONFIG" ]; then
  echo "Team not found: $TEAM" >&2
  exit 1
fi

# Serialize the read-modify-write against concurrent join/leave/rename on this
# team (#141), exactly as those scripts do.
agmsg_lock_acquire "$TEAM_DIR" || exit 1

# Every value below is escaped as a SQL string literal and spliced in, never
# bound via `.param set` — the sqlite3 shell's dot-command tokenizer doesn't
# honour SQL '' escaping, so a name or path containing a single quote would
# silently corrupt every later query (#87 cluster; same note in join.sh).
_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
AGENT_ID_SQL=$(_agmsg_sqlesc "$AGENT_ID")
AGENT_TYPE_SQL=$(_agmsg_sqlesc "$AGENT_TYPE")
NEW_PROJECT_SQL=$(_agmsg_sqlesc "$NEW_PROJECT")
CONFIG_SQL=$(agmsg_sql_readfile_path "$TEAM_CONFIG")

# Which registrations this run moves. Without --type, all of them.
if [ -n "$AGENT_TYPE" ]; then
  MATCH_EXPR="json_extract(value, '\$.type') = '$AGENT_TYPE_SQL'"
else
  MATCH_EXPR="1"
fi

EXISTING=$(agmsg_sqlite_mem "
  WITH cfg AS (SELECT CAST(readfile('$CONFIG_SQL') AS TEXT) AS json)
  SELECT value
  FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
  WHERE key = '$AGENT_ID_SQL';
")
if [ -z "$EXISTING" ] || [ "$EXISTING" = "null" ]; then
  agmsg_lock_release
  echo "Agent $AGENT_ID not in team $TEAM" >&2
  exit 1
fi

# Legacy single-registration records ({type, project} at the top level) still
# exist in the wild; normalize to the array shape first so the rewrite below
# has one form to handle (same CASE as join.sh/reset.sh).
EXISTING_ESCAPED=$(_agmsg_sqlesc "$EXISTING")
NORMALIZED=$(agmsg_sqlite_mem "
  WITH agent(a) AS (SELECT '$EXISTING_ESCAPED')
  SELECT CASE
    WHEN json_type(json_extract(a, '\$.registrations')) = 'array' THEN a
    ELSE json_object(
      'registrations',
      json_array(json_object(
        'type', json_extract(a, '\$.type'),
        'project', json_extract(a, '\$.project')
      ))
    )
  END
  FROM agent;
")
NORMALIZED_ESCAPED=$(_agmsg_sqlesc "$NORMALIZED")

MATCH_COUNT=$(agmsg_sqlite_mem "
  SELECT count(*)
  FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
  WHERE $MATCH_EXPR;
")
if [ "${MATCH_COUNT:-0}" -eq 0 ]; then
  agmsg_lock_release
  if [ -n "$AGENT_TYPE" ]; then
    echo "No '$AGENT_TYPE' registration for $AGENT_ID in team $TEAM" >&2
  else
    echo "No registrations for $AGENT_ID in team $TEAM" >&2
  fi
  exit 1
fi

# Rewrite the matching registrations' project, then collapse duplicates: moving
# a claude-code registration onto a path where the same agent already has one
# would otherwise leave two identical entries. GROUP BY on the rebuilt object
# text dedupes; MIN(key) keeps the surviving entries in their original order.
UPDATED_REGS=$(agmsg_sqlite_mem "
  SELECT COALESCE((
    SELECT json_group_array(json(reg))
    FROM (
      SELECT json_object(
               'type', json_extract(value, '\$.type'),
               'project', CASE WHEN $MATCH_EXPR THEN '$NEW_PROJECT_SQL'
                               ELSE json_extract(value, '\$.project') END
             ) AS reg,
             MIN(key) AS ord
      FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
      GROUP BY reg
      ORDER BY ord
    )
  ), json('[]'));
")
UPDATED_REGS_ESCAPED=$(_agmsg_sqlesc "$UPDATED_REGS")
AGENT_OBJ=$(agmsg_sqlite_mem "
  SELECT json_set('$NORMALIZED_ESCAPED', '\$.registrations', json('$UPDATED_REGS_ESCAPED'));
")
AGENT_OBJ_ESCAPED=$(_agmsg_sqlesc "$AGENT_OBJ")

# json_set on the '$.agents.<name>' path (parity with leave.sh/reset.sh), NOT
# join.sh's json_patch-onto-agents form: json_patch does an RFC7396 MERGE, so
# on a legacy top-level {type,project} record it would leave those two keys
# sitting alongside the freshly-added `registrations` array instead of the
# normalization above actually taking effect. json_set replaces the agent's
# value outright. The name is concatenated into the path string rather than
# used as a JSON object key, but that's safe: agmsg_validate_agent_name
# already rejects '.', '/', '\', '"', '[', ']' (#87 cluster), so it can't be
# reinterpreted as a different path segment.
UPDATED=$(agmsg_sqlite_mem "
  WITH cfg AS (SELECT CAST(readfile('$CONFIG_SQL') AS TEXT) AS json)
  SELECT json_set(cfg.json, '\$.agents.' || '$AGENT_ID_SQL', json('$AGENT_OBJ_ESCAPED'))
  FROM cfg;
")
if [ -z "$UPDATED" ]; then
  agmsg_lock_release
  echo "Failed to update $TEAM_CONFIG" >&2
  exit 1
fi
agmsg_write_atomic "$TEAM_CONFIG" "$UPDATED"
agmsg_lock_release

echo "Set project for $AGENT_ID in $TEAM: $NEW_PROJECT"
