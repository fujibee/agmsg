#!/usr/bin/env bash
set -euo pipefail

# Usage: join.sh <team> <agent_id> <type> <project_path>
#
# Adds an agent to a team. Creates the team if it doesn't exist.

TEAM="${1:?Usage: join.sh <team> <agent_id> <type> <project_path>}"
AGENT_ID="${2:?Missing agent_id}"
AGENT_TYPE="${3:?Missing type (claude-code | codex)}"
PROJECT_PATH="${4:?Missing project_path}"

# Reject unknown agent types — the rest of agmsg (delivery.sh,
# session-start.sh, identities.sh lookups) only supports the values listed
# here. Allowing arbitrary strings silently mis-registers an agent and
# makes monitor mode fail with a confusing "no joined teams" message.
case "$AGENT_TYPE" in
  claude-code|codex|gemini|antigravity|copilot|opencode) ;;
  *) echo "Unknown agent type: '$AGENT_TYPE' (supported: claude-code, codex, gemini, antigravity, copilot, opencode)" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

# Resolve the session's real project root from the passed pwd (see #92), so an
# agent-driven join from a subdir/worktree registers under the project the
# session lives in instead of minting a phantom record for the subdir.
# Callers passing an explicit, deliberate path (e.g. spawn.sh's --project, which
# may not be registered yet) set AGMSG_RESOLVE_PROJECT=0 to keep their path.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

# Keep this entrypoint's pre-join project resolver on the same readfile() path
# as the registry writes below. The sourced helper is shared with files outside
# this fix's scope, so override only the scan it calls here.
agmsg_registered_projects() {
  local type="$1" teams_dir="$SKILL_DIR/teams" config_file cfg_sql type_sql
  [ -d "$teams_dir" ] || return 0
  type_sql=$(printf '%s' "$type" | sed "s/'/''/g")
  for config_file in "$teams_dir"/*/config.json; do
    [ -f "$config_file" ] || continue
    cfg_sql=$(printf '%s' "$config_file" | sed "s/'/''/g")
    sqlite3 :memory: "
      WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
      cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw),
      agents AS (
        SELECT CASE
          WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
          ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
        END AS registrations
        FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
      )
      SELECT DISTINCT json_extract(r.value, '\$.project')
      FROM agents, json_each(agents.registrations) AS r
      WHERE json_extract(r.value, '\$.type') = '$type_sql';
    "
  done
}

PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE" 2>/dev/null || printf '%s' "$PROJECT_PATH")"

TEAM_CONFIG="$TEAMS_DIR/$TEAM/config.json"

# --- Ensure team config exists ---
mkdir -p "$TEAMS_DIR/$TEAM"
if [ ! -f "$TEAM_CONFIG" ]; then
  cat > "$TEAM_CONFIG" <<EOF
{
  "name": "$TEAM",
  "agents": {},
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  echo "Created team: $TEAM"
fi

# --- Add or extend agent registrations ---
CONFIG_SQL=$(printf '%s' "$TEAM_CONFIG" | sed "s/'/''/g")
AGENT_ID_SQL=$(printf '%s' "$AGENT_ID" | sed "s/'/''/g")
AGENT_TYPE_SQL=$(printf '%s' "$AGENT_TYPE" | sed "s/'/''/g")
PROJECT_SQL=$(printf '%s' "$PROJECT_PATH" | sed "s/'/''/g")
REGISTRATION=$(sqlite3 :memory: "SELECT json_object('type', '$AGENT_TYPE_SQL', 'project', '$PROJECT_SQL');")
REGISTRATION_ESCAPED=$(printf '%s' "$REGISTRATION" | sed "s/'/''/g")

EXISTING=$(sqlite3 :memory: "
  WITH cfg AS (SELECT CAST(readfile('$CONFIG_SQL') AS TEXT) AS json)
  SELECT value
  FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
  WHERE key = '$AGENT_ID_SQL';
")

if [ -z "$EXISTING" ] || [ "$EXISTING" = "null" ]; then
  AGENT_OBJ=$(sqlite3 :memory: "SELECT json_object('registrations', json_array(json('$REGISTRATION_ESCAPED')));")
else
  EXISTING_ESCAPED=$(printf '%s' "$EXISTING" | sed "s/'/''/g")
  NORMALIZED=$(sqlite3 :memory: "
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
  NORMALIZED_ESCAPED=$(printf '%s' "$NORMALIZED" | sed "s/'/''/g")

  HAS_REGISTRATION=$(sqlite3 :memory: "
    SELECT EXISTS(
      SELECT 1
      FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
      WHERE json_extract(value, '\$.type') = '$AGENT_TYPE_SQL'
        AND json_extract(value, '\$.project') = '$PROJECT_SQL'
    );
  ")

  if [ "$HAS_REGISTRATION" = "1" ]; then
    AGENT_OBJ="$NORMALIZED"
  else
    AGENT_OBJ=$(sqlite3 :memory: "
      SELECT json_set(
        '$NORMALIZED_ESCAPED',
        '\$.registrations[' || json_array_length(json_extract('$NORMALIZED_ESCAPED', '\$.registrations')) || ']',
        json('$REGISTRATION_ESCAPED')
      );
    ")
  fi
fi

AGENT_OBJ_ESCAPED=$(printf '%s' "$AGENT_OBJ" | sed "s/'/''/g")
UPDATED=$(sqlite3 :memory: \
  "WITH cfg AS (SELECT CAST(readfile('$CONFIG_SQL') AS TEXT) AS json)
  SELECT json_set(
    cfg.json,
    '\$.agents',
    json_patch(
      CASE
        WHEN json_type(json_extract(cfg.json, '\$.agents')) = 'object' THEN json_extract(cfg.json, '\$.agents')
        ELSE json('{}')
      END,
      json_object('$AGENT_ID_SQL', json('$AGENT_OBJ_ESCAPED'))
    )
  )
  FROM cfg;")
echo "$UPDATED" > "$TEAM_CONFIG"

echo "Joined team $TEAM as $AGENT_ID"
