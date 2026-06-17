#!/usr/bin/env bash
set -euo pipefail

# Show agent identity in id(1) style.
# Single match:    agent=<name> teams=<t1,t2,...> type=<type> project=<path>
# Multiple match:  multiple=true agents=<n1,n2,...> teams=<t1,t2,...> type=<type> project=<path>
# Suggestions:     suggest=true agents=<n1,n2,...> teams=<t1,t2,...> type=<type> project=<path> available_teams=<...>
# Not joined:      not_joined=true available_teams=<t1,t2,...> (or "none")
#
# Usage: whoami.sh <project_path> [type]
#   type: claude-code, codex, gemini, antigravity, copilot, opencode
#   If type is omitted, auto-detect from env vars and process tree.

# Auto-detect CLI type from environment variables and process tree
detect_cli_type() {
  # 1. Check environment variables. Order matters: prefer the env vars that
  # the runtime *itself* exports for its own session over the env vars users
  # commonly set globally for unrelated reasons. CLAUDE_CODE_SESSION_ID and
  # CODEX_SANDBOX / CODEX_THREAD_ID are set by their runtimes only. The
  # GEMINI_API_KEY family is also routinely set by users of the Gemini API
  # SDK without the Gemini CLI being involved, so it goes last.
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "claude-code"
    return 0
  fi

  if [ -n "${CODEX_SANDBOX:-}" ] || [ -n "${CODEX_THREAD_ID:-}" ]; then
    echo "codex"
    return 0
  fi

  if [ -n "${GEMINI_API_KEY:-}" ] || [ -n "${GOOGLE_GEMINI_CLI:-}" ]; then
    echo "gemini"
    return 0
  fi

  # 2. Fall back to process tree detection
  local pid=$$
  local max_depth=10
  local depth=0

  while [ $depth -lt $max_depth ] && [ "$pid" != "1" ] && [ -n "$pid" ]; do
    # Get process name
    local proc_name
    proc_name=$(ps -p "$pid" -o comm= 2>/dev/null | xargs basename 2>/dev/null || true)

    case "$proc_name" in
      codex|codex-*)
        echo "codex"
        return 0
        ;;
      gemini|gemini-*)
        echo "gemini"
        return 0
        ;;
      claude|claude-code|claude-*)
        echo "claude-code"
        return 0
        ;;
      opencode|opencode-*)
        echo "opencode"
        return 0
        ;;
    esac

    # Move to parent process
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
    depth=$((depth + 1))
  done

  # Default fallback
  echo "claude-code"
}

PROJECT_PATH="${1:?Usage: whoami.sh <project_path> [type]}"
AGENT_TYPE="${2:-$(detect_cli_type)}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

# Resolve the session's real project root from the passed pwd (see #92): a cd
# into a subdir/worktree must not be treated as a fresh, unregistered project.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

if [ ! -d "$TEAMS_DIR" ]; then
  echo "not_joined=true available_teams=none"
  exit 0
fi

# Exact (project, type) matches come from the shared identities helper.
# Format: each line "<team>\t<agent>".
EXACT_MATCHES="$("$SCRIPT_DIR/identities.sh" "$PROJECT_PATH" "$AGENT_TYPE")"

# Suggestions = any agents of this type registered elsewhere, plus the list
# of all teams on disk. These still need a full scan since identities.sh is
# scoped to the exact (project, type).
SUGGESTED_MATCHES=""
ALL_TEAMS=""

for config_file in "$TEAMS_DIR"/*/config.json; do
  [ -f "$config_file" ] || continue
  CONFIG_ESCAPED=$(sed "s/'/''/g" "$config_file")
  TEAM_NAME=$(sqlite3 :memory: ".param set :json '$CONFIG_ESCAPED'" \
    "SELECT json_extract(:json, '$.name');")
  ALL_TEAMS="${ALL_TEAMS:+$ALL_TEAMS,}$TEAM_NAME"

  while IFS='	' read -r agent_name; do
    [ -n "$agent_name" ] || continue
    SUGGESTED_MATCHES="${SUGGESTED_MATCHES:+$SUGGESTED_MATCHES
}$TEAM_NAME	$agent_name"
  done < <(sqlite3 -separator '	' :memory: ".param set :json '$CONFIG_ESCAPED'" "
    WITH agents AS (
      SELECT
        key AS name,
        CASE
          WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
          ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
        END AS registrations
      FROM json_each(json_extract(:json, '\$.agents'))
    )
    SELECT DISTINCT name
    FROM agents, json_each(agents.registrations) AS r
    WHERE json_extract(r.value, '\$.type') = '$AGENT_TYPE';
  ")
done

if [ -z "$EXACT_MATCHES" ] && [ -z "$SUGGESTED_MATCHES" ]; then
  echo "not_joined=true available_teams=${ALL_TEAMS:-none}"
  exit 0
fi

if [ -z "$EXACT_MATCHES" ]; then
  # SUGGESTED_MATCHES is "team\tagent" per line; preserve that order.
  AGENT_NAMES=$(echo "$SUGGESTED_MATCHES" | cut -f2 | awk '!seen[$0]++' | paste -sd, -)
  TEAM_NAMES=$(echo "$SUGGESTED_MATCHES" | cut -f1 | awk '!seen[$0]++' | paste -sd, -)
  echo "suggest=true agents=$AGENT_NAMES teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH available_teams=${ALL_TEAMS:-none}"
  exit 0
fi

# EXACT_MATCHES from identities.sh is "team\tagent" per line.
TEAM_NAMES=$(echo "$EXACT_MATCHES" | cut -f1 | awk '!seen[$0]++' | paste -sd, -)
AGENT_NAMES=$(echo "$EXACT_MATCHES" | cut -f2 | awk '!seen[$0]++' | paste -sd, -)
AGENT_COUNT=$(echo "$EXACT_MATCHES" | cut -f2 | sort -u | wc -l | tr -d ' ')

if [ "$AGENT_COUNT" -eq 1 ]; then
  echo "agent=$AGENT_NAMES teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH"
else
  echo "multiple=true agents=$AGENT_NAMES teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH"
fi
