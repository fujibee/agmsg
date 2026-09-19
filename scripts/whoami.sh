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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/detect-cli-type.sh"

PROJECT_PATH="${1:?Usage: whoami.sh <project_path> [type]}"
AGENT_TYPE="${2:-$(agmsg_detect_cli_type)}"

# Reject an unknown type the caller ASKED for, the same check join.sh makes
# (#783). Without it a wrong or misspelled $2 reads all the way through to
# `not_joined=true` — a true answer to a different question ("are you
# registered under this exact, wrong type?"), which looks like ordinary output
# rather than an error, so nobody doubts it and they go and join again.
#
# GUARDED ON $2 BEING PRESENT, following doctor.sh's --type check, and that is
# not tidiness. agmsg_detect_cli_type's value is NOT guaranteed to be a member of
# the registry: two of its three exits echo a name read out of
# agmsg_known_types, but the third is the literal `claude-code` fallback at the
# end of lib/detect-cli-type.sh, which no registry lookup stands behind.
# Validating the RESOLVED value ties
# the no-argument path to that literal still being discoverable — so a broken
# install, or a trust decision that drops the built-in base, would stop
# everyone rather than only the person who mistyped a type. Measured: with
# `claude-code` renamed out of scripts/drivers/types/, validating the resolved
# value turns a plain `whoami.sh <project>` into exit 1, while the same tree
# without the check still answers.
if [ -n "${2:-}" ] && ! agmsg_is_known_type "$AGENT_TYPE"; then
  echo "Unknown agent type: '$AGENT_TYPE' (supported: $(agmsg_known_types | sort -u | paste -sd, - | sed 's/,/, /g'))" >&2
  exit 1
fi

# SCRIPT_DIR is already resolved above (before sourcing the type registry).
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

# Resolve the session's real project root from the passed pwd (see #92): a cd
# into a subdir/worktree must not be treated as a fresh, unregistered project.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"
AGENT_TYPE_SQL=$(printf '%s' "$AGENT_TYPE" | sed "s/'/''/g")

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
  cfg_sql=$(agmsg_sql_readfile_path "$config_file")
  TEAM_NAME=$(agmsg_sqlite_mem "
    WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
    cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
    SELECT json_extract(json, '\$.name') FROM cfg;
  ")
  if [ -n "$TEAM_NAME" ] && [ "$TEAM_NAME" != "null" ]; then
    ALL_TEAMS="${ALL_TEAMS:+$ALL_TEAMS,}$TEAM_NAME"
  fi

  while IFS='	' read -r agent_name; do
    [ -n "$agent_name" ] || continue
    SUGGESTED_MATCHES="${SUGGESTED_MATCHES:+$SUGGESTED_MATCHES
}$TEAM_NAME	$agent_name"
  done < <(sqlite3 -separator '	' :memory: "
    WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
    cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw),
    agents AS (
      SELECT
        key AS name,
        CASE
          WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
          ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
        END AS registrations
      FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
    )
    SELECT DISTINCT name
    FROM agents, json_each(agents.registrations) AS r
    WHERE json_extract(r.value, '\$.type') = '$AGENT_TYPE_SQL';
  " | tr -d '\r')
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
