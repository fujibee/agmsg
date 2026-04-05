#!/usr/bin/env bash
set -euo pipefail

# Manage auto message checking hooks.
# Usage: hook.sh on  <type> <project_path>
#        hook.sh off <type> <project_path>

ACTION="${1:?Usage: hook.sh on|off ...}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_NAME="$(basename "$SKILL_DIR")"

# Read settings file or return empty object, escaped for SQL
read_settings_escaped() {
  if [ -f "$1" ]; then
    sed "s/'/''/g" "$1"
  else
    echo '{}'
  fi
}

# --- Actions ---

do_on() {
  local TYPE="${1:?Usage: hook.sh on <type> <project_path>}"
  local PROJECT="${2:?Missing project_path}"

  case "$TYPE" in
    claude-code)
      local SETTINGS_FILE="$PROJECT/.claude/settings.local.json"
      local CHECK_CMD="'$SKILL_DIR/scripts/check-inbox.sh' '$TYPE' '$PROJECT'"
      mkdir -p "$PROJECT/.claude"

      local SETTINGS_ESC
      SETTINGS_ESC=$(read_settings_escaped "$SETTINGS_FILE")
      local HOOK_ENTRY="{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$CHECK_CMD\"}]}"
      local HOOK_ESC
      HOOK_ESC=$(echo "$HOOK_ENTRY" | sed "s/'/''/g")

      local UPDATED
      UPDATED=$(sqlite3 :memory: "
        SELECT CASE
          WHEN json_extract('$SETTINGS_ESC', '\$.hooks.Stop') IS NULL THEN
            json_set(
              CASE WHEN json_extract('$SETTINGS_ESC', '\$.hooks') IS NULL
                THEN json_set('$SETTINGS_ESC', '\$.hooks', json('{}'))
                ELSE '$SETTINGS_ESC'
              END,
              '\$.hooks.Stop', json_array(json('$HOOK_ESC')))
          WHEN EXISTS (
            SELECT 1 FROM json_each(json_extract('$SETTINGS_ESC', '\$.hooks.Stop')) AS s,
              json_each(json_extract(s.value, '\$.hooks')) AS h
            WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
          ) THEN
            json_set('$SETTINGS_ESC', '\$.hooks.Stop',
              (SELECT json_group_array(
                CASE
                  WHEN EXISTS (
                    SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
                    WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
                  ) THEN json('$HOOK_ESC')
                  ELSE json(s.value)
                END
              ) FROM json_each(json_extract('$SETTINGS_ESC', '\$.hooks.Stop')) AS s)
            )
          ELSE
            json_set('$SETTINGS_ESC', '\$.hooks.Stop',
              (SELECT json_group_array(json(v.value))
               FROM (
                 SELECT value FROM json_each(json_extract('$SETTINGS_ESC', '\$.hooks.Stop'))
                 UNION ALL
                 SELECT '$HOOK_ESC'
               ) v)
            )
        END;
      ")
      echo "$UPDATED" > "$SETTINGS_FILE"
      echo "Hook enabled for $PROJECT (claude-code)"
      ;;
    codex)
      echo "Codex hook support not yet implemented"
      exit 1
      ;;
    *)
      echo "Unknown type: $TYPE" >&2
      exit 1
      ;;
  esac
}

do_off() {
  local TYPE="${1:?Usage: hook.sh off <type> <project_path>}"
  local PROJECT="${2:?Missing project_path}"

  case "$TYPE" in
    claude-code)
      local SETTINGS_FILE="$PROJECT/.claude/settings.local.json"

      if [ ! -f "$SETTINGS_FILE" ]; then
        echo "No hook configured"
        exit 0
      fi

      local SETTINGS_ESC
      SETTINGS_ESC=$(sed "s/'/''/g" "$SETTINGS_FILE")

      local UPDATED
      UPDATED=$(sqlite3 :memory: "
        SELECT CASE
          WHEN json_extract('$SETTINGS_ESC', '\$.hooks.Stop') IS NULL THEN
            'NO_HOOK'
          WHEN NOT EXISTS (
            SELECT 1 FROM json_each(json_extract('$SETTINGS_ESC', '\$.hooks.Stop')) AS s,
              json_each(json_extract(s.value, '\$.hooks')) AS h
            WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
          ) THEN
            'NO_HOOK'
          WHEN (SELECT count(*) FROM json_each(json_extract('$SETTINGS_ESC', '\$.hooks.Stop')) AS s
                WHERE NOT EXISTS (
                  SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
                  WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
                )) = 0 THEN
            CASE
              WHEN (SELECT count(*) FROM json_each(json_extract(json_remove('$SETTINGS_ESC', '\$.hooks.Stop'), '\$.hooks'))) = 0 THEN
                json_remove('$SETTINGS_ESC', '\$.hooks')
              ELSE
                json_remove('$SETTINGS_ESC', '\$.hooks.Stop')
            END
          ELSE
            json_set('$SETTINGS_ESC', '\$.hooks.Stop',
              (SELECT json_group_array(json(s.value))
               FROM json_each(json_extract('$SETTINGS_ESC', '\$.hooks.Stop')) AS s
               WHERE NOT EXISTS (
                 SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
                 WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
               ))
            )
        END;
      ")

      if [ "$UPDATED" = "NO_HOOK" ]; then
        echo "No hook configured"
      else
        echo "$UPDATED" > "$SETTINGS_FILE"
        echo "Hook disabled for $PROJECT (claude-code)"
      fi
      ;;
    codex)
      echo "Codex hook support not yet implemented"
      exit 1
      ;;
    *)
      echo "Unknown type: $TYPE" >&2
      exit 1
      ;;
  esac
}

# --- Dispatch ---

case "$ACTION" in
  on)  do_on "$@" ;;
  off) do_off "$@" ;;
  *)   echo "Unknown action: $ACTION (use on|off)" >&2; exit 1 ;;
esac
