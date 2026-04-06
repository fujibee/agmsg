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

# Resolve hooks file path and ensure parent directory exists
resolve_hooks_file() {
  local type="$1"
  local project="$2"

  case "$type" in
    claude-code)
      mkdir -p "$project/.claude"
      echo "$project/.claude/settings.local.json"
      ;;
    codex)
      mkdir -p "$project/.codex"
      echo "$project/.codex/hooks.json"
      ;;
    *)
      echo "Unknown type: $type" >&2
      return 1
      ;;
  esac
}

# Add or update agmsg Stop hook in a JSON hooks file
add_hook() {
  local settings_file="$1"
  local check_cmd="$2"

  local SETTINGS_ESC
  SETTINGS_ESC=$(read_settings_escaped "$settings_file")
  local HOOK_ENTRY="{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$check_cmd\"}]}"
  local HOOK_ESC
  HOOK_ESC=$(echo "$HOOK_ENTRY" | sed "s/'/''/g")

  sqlite3 :memory: "
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
  "
}

# Remove agmsg Stop hook from a JSON hooks file
remove_hook() {
  local settings_file="$1"

  if [ ! -f "$settings_file" ]; then
    echo "NO_HOOK"
    return
  fi

  local SETTINGS_ESC
  SETTINGS_ESC=$(sed "s/'/''/g" "$settings_file")

  sqlite3 :memory: "
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
  "
}

# Enable codex_hooks feature flag in config.toml
enable_codex_hooks_feature() {
  local codex_config="$HOME/.codex/config.toml"
  [ -f "$codex_config" ] || return 0

  if grep -q 'codex_hooks' "$codex_config" 2>/dev/null; then
    return 0
  fi

  if grep -q '^\[features\]' "$codex_config" 2>/dev/null; then
    awk '
      { print }
      /^\[features\]/ { print "codex_hooks = true" }
    ' "$codex_config" > "$codex_config.tmp" && mv "$codex_config.tmp" "$codex_config"
  else
    printf '\n[features]\ncodex_hooks = true\n' >> "$codex_config"
  fi
}

# --- Actions ---

do_on() {
  local TYPE="${1:?Usage: hook.sh on <type> <project_path>}"
  local PROJECT="${2:?Missing project_path}"

  local HOOKS_FILE
  HOOKS_FILE=$(resolve_hooks_file "$TYPE" "$PROJECT") || exit 1
  local CHECK_CMD="'$SKILL_DIR/scripts/check-inbox.sh' '$TYPE' '$PROJECT'"

  local UPDATED
  UPDATED=$(add_hook "$HOOKS_FILE" "$CHECK_CMD")
  echo "$UPDATED" > "$HOOKS_FILE"

  if [ "$TYPE" = "codex" ]; then
    enable_codex_hooks_feature
  fi

  echo "Hook enabled for $PROJECT ($TYPE)"
  echo "Restart your agent to activate the hook."
}

do_off() {
  local TYPE="${1:?Usage: hook.sh off <type> <project_path>}"
  local PROJECT="${2:?Missing project_path}"

  local HOOKS_FILE
  HOOKS_FILE=$(resolve_hooks_file "$TYPE" "$PROJECT") || exit 1

  local UPDATED
  UPDATED=$(remove_hook "$HOOKS_FILE")

  if [ "$UPDATED" = "NO_HOOK" ]; then
    echo "No hook configured"
  else
    echo "$UPDATED" > "$HOOKS_FILE"
    echo "Hook disabled for $PROJECT ($TYPE)"
    echo "Restart your agent to deactivate the hook."
  fi
}

# --- Dispatch ---

case "$ACTION" in
  on)  do_on "$@" ;;
  off) do_off "$@" ;;
  *)   echo "Unknown action: $ACTION (use on|off)" >&2; exit 1 ;;
esac
