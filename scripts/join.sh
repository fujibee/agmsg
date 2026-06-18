#!/usr/bin/env bash
set -euo pipefail

# Usage: join.sh <team> <agent_id> <type> <project_path>
#
# Adds an agent to a team. Creates the team if it doesn't exist.

TEAM="${1:?Usage: join.sh <team> <agent_id> <type> <project_path>}"
AGENT_ID="${2:?Missing agent_id}"
AGENT_TYPE="${3:?Missing type (a registered type under types/<name>/)}"
PROJECT_PATH="${4:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"

# Reject unknown agent types — the rest of agmsg (delivery.sh,
# session-start.sh, identities.sh lookups) only supports registered types
# (types/<name>/type.conf). Allowing arbitrary strings silently mis-registers an
# agent and makes monitor mode fail with a confusing "no joined teams" message.
if ! agmsg_is_known_type "$AGENT_TYPE"; then
  echo "Unknown agent type: '$AGENT_TYPE' (supported: $(agmsg_known_types | sort -u | paste -sd, - | sed 's/,/, /g'))" >&2
  exit 1
fi

SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

# Resolve the session's real project root from the passed pwd (see #92), so an
# agent-driven join from a subdir/worktree registers under the project the
# session lives in instead of minting a phantom record for the subdir.
# Callers passing an explicit, deliberate path (e.g. spawn.sh's --project, which
# may not be registered yet) set AGMSG_RESOLVE_PROJECT=0 to keep their path.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

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
CONFIG_ESCAPED=$(sed "s/'/''/g" "$TEAM_CONFIG")
REGISTRATION="{\"type\":\"$AGENT_TYPE\",\"project\":\"$PROJECT_PATH\"}"
REGISTRATION_ESCAPED=$(printf '%s' "$REGISTRATION" | sed "s/'/''/g")

EXISTING=$(sqlite3 :memory: ".param set :json '$CONFIG_ESCAPED'" \
  "SELECT json_extract(:json, '$.agents.$AGENT_ID');")

if [ -z "$EXISTING" ] || [ "$EXISTING" = "null" ]; then
  AGENT_OBJ="{\"registrations\":[${REGISTRATION}]}"
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
      WHERE json_extract(value, '\$.type') = '$AGENT_TYPE'
        AND json_extract(value, '\$.project') = '$PROJECT_PATH'
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

UPDATED=$(sqlite3 :memory: \
  ".param set :json '$CONFIG_ESCAPED'" \
  "SELECT json_set(:json, '$.agents.$AGENT_ID', json('$(printf '%s' "$AGENT_OBJ" | sed "s/'/''/g")'));")
echo "$UPDATED" > "$TEAM_CONFIG"

echo "Joined team $TEAM as $AGENT_ID"
