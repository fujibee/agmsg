#!/usr/bin/env bash
set -euo pipefail

# agmsg — Agent Messaging uninstaller
# Removes messaging skill, commands, hooks, and optionally DB/teams.
#
# Usage:
#   ./uninstall.sh                    # Interactive (confirms each step)
#   ./uninstall.sh --yes              # Remove all without confirmation
#   ./uninstall.sh --keep-data        # Remove skill but keep DB and teams

AGENTS_DIR="$HOME/.agents"

AUTO_YES=false
KEEP_DATA=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)       AUTO_YES=true;  shift ;;
    --keep-data)    KEEP_DATA=true; shift ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [options]"
      echo ""
      echo "Options:"
      echo "  --yes, -y       Remove all without confirmation"
      echo "  --keep-data     Remove skill but keep DB and team configs"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo ""
echo "  agmsg — Uninstall"
echo "  ──────────────────"
echo ""

confirm() {
  if [ "$AUTO_YES" = true ]; then return 0; fi
  printf "  %s (y/n) [n]: " "$1"
  read -r input
  [ "${input:-n}" = "y" ] || [ "${input:-n}" = "Y" ]
}

# --- Find installed skill directories ---
SKILL_DIRS=()
for d in "$AGENTS_DIR"/skills/*/; do
  if [ -f "${d}.agmsg" ]; then
    SKILL_DIRS+=("${d%/}")
  fi
done

if [ ${#SKILL_DIRS[@]} -eq 0 ]; then
  echo "  Nothing to remove (not installed?)"
  echo ""
  exit 0
fi

echo "  Found installation(s):"
for sd in "${SKILL_DIRS[@]}"; do
  echo "    $(basename "$sd") → $sd"
done
echo ""

REMOVED=false

# --- 1. Remove slash commands and hooks from joined projects ---
for SKILL_DIR in "${SKILL_DIRS[@]}"; do
  TEAMS_DIR="$SKILL_DIR/teams"
  [ -d "$TEAMS_DIR" ] || continue

  echo "  Scanning joined projects for commands and hooks..."
  for config in "$TEAMS_DIR"/*/config.json; do
    [ -f "$config" ] || continue

    projects=$(sqlite3 -separator '	' :memory: \
      ".param set :json '$(sed "s/'/''/g" "$config")'" \
      "SELECT json_extract(value, '$.project') FROM json_each(json_extract(:json, '$.agents'))
       WHERE json_extract(value, '$.type') = 'claude-code'
         AND json_extract(value, '$.project') IS NOT NULL;" 2>/dev/null || true)

    while IFS= read -r project; do
      [ -n "$project" ] || continue

      # Remove command files that reference agmsg scripts
      if [ -d "$project/.claude/commands" ]; then
        for cmd_file in "$project/.claude/commands"/*.md; do
          [ -f "$cmd_file" ] || continue
          if grep -q "scripts/whoami.sh\|scripts/inbox.sh\|scripts/send.sh" "$cmd_file" 2>/dev/null; then
            cmd_name=$(basename "$cmd_file" .md)
            rm "$cmd_file"
            echo "  - removed /$cmd_name command from $project"
            REMOVED=true
          fi
        done
      fi

      # Remove only agmsg hook entries from settings files (preserve other hooks)
      SKILL_NAME="$(basename "$SKILL_DIR")"
      for settings_file in "$project/.claude/settings.json" "$project/.claude/settings.local.json"; do
        if [ -f "$settings_file" ] && grep -q "$SKILL_NAME" "$settings_file" 2>/dev/null; then
          SETTINGS_ESC=$(sed "s/'/''/g" "$settings_file")
          UPDATED=$(sqlite3 :memory: "
            WITH hook_types(ht) AS (VALUES ('Stop'), ('PostToolUse'))
            SELECT COALESCE(
              (SELECT result FROM (
                SELECT '$SETTINGS_ESC' AS result
              ) WHERE NOT EXISTS (
                SELECT 1 FROM hook_types, json_each(json_extract('$SETTINGS_ESC', '\$.hooks.' || ht)) AS e,
                  json_each(json_extract(e.value, '\$.hooks')) AS h
                WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
              )),
              (SELECT CASE
                WHEN (SELECT count(*) FROM json_each(json_extract(filtered, '\$.hooks'))
                      WHERE json_array_length(value) > 0 OR json_type(value) != 'array') = 0
                THEN json_remove(filtered, '\$.hooks')
                ELSE filtered
              END
              FROM (
                SELECT json_set(json_set('$SETTINGS_ESC',
                  '\$.hooks.Stop',
                  COALESCE((SELECT json_group_array(json(e.value))
                    FROM json_each(json_extract('$SETTINGS_ESC', '\$.hooks.Stop')) AS e
                    WHERE NOT EXISTS (
                      SELECT 1 FROM json_each(json_extract(e.value, '\$.hooks')) AS h
                      WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
                    )), json('[]'))),
                  '\$.hooks.PostToolUse',
                  COALESCE((SELECT json_group_array(json(e.value))
                    FROM json_each(json_extract('$SETTINGS_ESC', '\$.hooks.PostToolUse')) AS e
                    WHERE NOT EXISTS (
                      SELECT 1 FROM json_each(json_extract(e.value, '\$.hooks')) AS h
                      WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
                    )), json('[]'))) AS filtered
              ))
            );
          " 2>/dev/null) || true
          if [ -n "$UPDATED" ] && [ "$UPDATED" != "$SETTINGS_ESC" ]; then
            echo "$UPDATED" > "$settings_file"
            echo "  - removed agmsg hook from $settings_file"
            REMOVED=true
          fi
        fi
      done
    done <<< "$projects"
  done
done

# --- 2. Remove Claude Code global command ---
for SKILL_DIR in "${SKILL_DIRS[@]}"; do
  SKILL_NAME="$(basename "$SKILL_DIR")"
  CC_CMD="$HOME/.claude/commands/$SKILL_NAME.md"
  if [ -f "$CC_CMD" ]; then
    rm "$CC_CMD"
    echo "  - removed /$SKILL_NAME from ~/.claude/commands/"
    REMOVED=true
  fi
done

# --- 3. Remove skill directories ---
for SKILL_DIR in "${SKILL_DIRS[@]}"; do
  SKILL_NAME="$(basename "$SKILL_DIR")"
  if [ "$KEEP_DATA" = true ]; then
    echo ""
    echo "  Removing $SKILL_NAME skill (keeping DB and teams)..."
    rm -rf "$SKILL_DIR/scripts" "$SKILL_DIR/templates" "$SKILL_DIR/agents"
    rm -f "$SKILL_DIR/SKILL.md"
    echo "  - removed scripts, templates, SKILL.md"
    echo "  ~ preserved $SKILL_DIR/db/ and $SKILL_DIR/teams/"
    REMOVED=true
  else
    echo ""
    if confirm "Remove $SKILL_NAME (including DB and teams)?"; then
      rm -rf "$SKILL_DIR"
      echo "  - removed $SKILL_DIR"
      REMOVED=true
    fi
  fi
done

# --- 4. Clean up Codex writable_roots ---
CODEX_CONFIG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CONFIG" ]; then
  needs_cleanup=false
  for SKILL_DIR in "${SKILL_DIRS[@]}"; do
    if grep -q "$SKILL_DIR" "$CODEX_CONFIG" 2>/dev/null; then
      needs_cleanup=true
      break
    fi
  done

  if [ "$needs_cleanup" = true ]; then
    cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak"
    # Build pattern of skill dirs to remove
    skill_pattern=$(printf '|%s' "${SKILL_DIRS[@]}")
    skill_pattern="${skill_pattern:1}"  # remove leading |

    # Remove matching entries from writable_roots (handles multiline arrays)
    awk -v pattern="$skill_pattern" '
      /writable_roots/ { in_roots=1; buf="" }
      in_roots { buf = buf $0 "\n" }
      in_roots && /\]/ {
        # Remove entries matching skill dirs
        n = split(pattern, pats, "|")
        for (i = 1; i <= n; i++) {
          gsub("\"" pats[i] "[^\"]*\"[, ]*", "", buf)
        }
        # Clean up trailing/leading commas
        gsub(/,[ \t]*\]/, "]", buf)
        gsub(/\[[ \t]*,/, "[", buf)
        gsub(/,[ \t]*,/, ",", buf)
        # Check if empty
        if (buf ~ /writable_roots[^[]*\[\s*\]/) {
          in_roots=0; next
        }
        printf "%s", buf
        in_roots=0; next
      }
      !in_roots { print }
    ' "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp" && mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
    # Remove empty [sandbox_workspace_write] section
    awk '
      /^\[sandbox_workspace_write\]/ {
        header=$0
        if (getline nextline <= 0) next
        if (nextline ~ /^\[/ || nextline == "") { print nextline; next }
        print header
        print nextline
        next
      }
      { print }
    ' "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp" && mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
    echo "  - cleaned Codex writable_roots (backup: config.toml.bak)"
  fi
fi

# --- 5. Clean up empty ~/.agents/ ---
if [ -d "$AGENTS_DIR" ]; then
  rmdir "$AGENTS_DIR/skills" 2>/dev/null || true
  rmdir "$AGENTS_DIR" 2>/dev/null || true
fi

# --- Done ---
echo ""
if [ "$REMOVED" = true ]; then
  echo "  ✓ Uninstall complete"
else
  echo "  Nothing removed."
fi
echo ""
