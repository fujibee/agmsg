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

codex_bridge_label_for_base() {
  local base_name="${1##*/}" suffix
  case "$base_name" in codex-bridge.*) suffix="${base_name#codex-bridge.}" ;; *) return 1 ;; esac
  case "$suffix" in ""|*[!A-Za-z0-9._%-]*) return 1 ;; esac
  printf 'com.agmsg.codex-bridge.%s' "$suffix"
}

canonical_project_path() {
  local project="$1"
  if [ -d "$project" ]; then
    (cd -P "$project" 2>/dev/null && pwd -P)
  else
    printf '%s' "$project"
  fi
}

installed_bridge_pid_matches() {
  local pid="$1" base="$2" meta="$3" state_key project canonical_project type team name thread cmd expected prefix
  [ -f "$meta" ] || return 1
  state_key="${base##*/codex-bridge.}"
  case "$state_key" in ""|*[!A-Za-z0-9._%-]*) return 1 ;; esac
  project="$(sed -n 's/^project=//p' "$meta" | head -1)"
  type="$(sed -n 's/^type=//p' "$meta" | head -1)"
  team="$(sed -n 's/^team=//p' "$meta" | head -1)"
  name="$(sed -n 's/^name=//p' "$meta" | head -1)"
  thread="$(sed -n 's/^thread=//p' "$meta" | head -1)"
  canonical_project="$(canonical_project_path "$project")"
  [ "$type" = "codex" ] && [ -n "$canonical_project" ] && [ -n "$team" ] \
    && [ -n "$name" ] && [ -n "$thread" ] || return 1
  case "$thread" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  cmd="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  expected="$SKILL_DIR/scripts/drivers/types/codex/codex-bridge.js --project $project --type codex --team $team --name $name --state-key $state_key --app-server-file $base.appserver --thread $thread"
  case " $cmd " in *" $expected "*) return 0 ;; esac
  # Pre-state-key bridge records are still removable, but signaling one also
  # requires the full legacy project/role/thread argv contract.
  prefix="$SKILL_DIR/scripts/drivers/types/codex/codex-bridge.js --project $project --type codex --team $team --name $name --app-server "
  case " $cmd " in *" $prefix"*" --thread $thread "*) return 0 ;; esac
  return 1
}

# --- 0. Stop Codex role bridges and remove the global Desktop relay ---
# This is the only automatic path that removes the shared relay itself. Normal
# delivery mode changes stop project-owned role bridges but keep the relay for
# other projects and future visible tasks.
for SKILL_DIR in "${SKILL_DIRS[@]}"; do
  for plist in "$SKILL_DIR"/run/codex-bridge.*.plist; do
    [ -f "$plist" ] || continue
    base="${plist%.plist}"
    label="$(codex_bridge_label_for_base "$base" 2>/dev/null || true)"
    [ -n "$label" ] || continue
    if command -v launchctl >/dev/null 2>&1; then
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    fi
    pid="$(cat "$base.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      if installed_bridge_pid_matches "$pid" "$base" "$base.meta"; then
        kill "$pid" 2>/dev/null || true
      fi
    fi
    rm -f "$base.pid" "$base.meta" "$base.health" "$base.appserver" \
      "$base.plist" "$base.log" "$base.last-ids" "$base.binding"
    rm -f "$base".wake.*.json "$base.relay-wake.json"
  done
  for meta in "$SKILL_DIR"/run/codex-bridge.*.meta; do
    [ -f "$meta" ] || continue
    base="${meta%.meta}"
    label="$(codex_bridge_label_for_base "$base" 2>/dev/null || true)"
    [ -n "$label" ] || continue
    if command -v launchctl >/dev/null 2>&1; then
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    fi
    pid="$(cat "$base.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      if installed_bridge_pid_matches "$pid" "$base" "$meta"; then
        kill "$pid" 2>/dev/null || true
      fi
    fi
    rm -f "$base.pid" "$base.meta" "$base.health" "$base.appserver" \
      "$base.plist" "$base.log" "$base.last-ids" "$base.binding"
    rm -f "$base".wake.*.json "$base.relay-wake.json"
  done
  rm -f "$SKILL_DIR"/run/codex-seat.*.tsv
  for lock in "$SKILL_DIR"/run/actas.*.session; do
    [ -f "$lock" ] || continue
    owner="$(head -1 "$lock" 2>/dev/null || true)"
    case "$owner" in codex-seat:*) rm -f "$lock" ;; esac
  done
  relayctl="$SKILL_DIR/scripts/drivers/types/codex/codex-desktop-relayctl.sh"
  if [ -x "$relayctl" ]; then
    "$relayctl" disable >/dev/null 2>&1 || true
  fi
done

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

    # --- Copilot CLI project-scoped hook file cleanup ---
    copilot_projects=$(sqlite3 -separator '	' :memory: \
      ".param set :json '$(sed "s/'/''/g" "$config")'" \
      "SELECT json_extract(value, '$.project') FROM json_each(json_extract(:json, '$.agents'))
       WHERE json_extract(value, '$.type') = 'copilot'
         AND json_extract(value, '$.project') IS NOT NULL;" 2>/dev/null || true)

    while IFS= read -r project; do
      [ -n "$project" ] || continue
      copilot_hook="$project/.github/hooks/agmsg.json"
      if [ -f "$copilot_hook" ] && grep -q "$(basename "$SKILL_DIR")" "$copilot_hook" 2>/dev/null; then
        rm "$copilot_hook"
        echo "  - removed agmsg Copilot hook from $project"
        REMOVED=true
      fi
    done <<< "$copilot_projects"
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

# --- 2b. Remove Copilot CLI skill ---
for SKILL_DIR in "${SKILL_DIRS[@]}"; do
  SKILL_NAME="$(basename "$SKILL_DIR")"
  COPILOT_SKILL="$HOME/.copilot/skills/$SKILL_NAME"
  if [ -d "$COPILOT_SKILL" ]; then
    rm -rf "$COPILOT_SKILL"
    echo "  - removed /$SKILL_NAME skill from ~/.copilot/skills/"
    REMOVED=true
  fi
done

# --- 2c. Remove native Windows helpers ---
for SKILL_DIR in "${SKILL_DIRS[@]}"; do
  SKILL_NAME="$(basename "$SKILL_DIR")"
  for helper in "$AGENTS_DIR/$SKILL_NAME.ps1" "$AGENTS_DIR/$SKILL_NAME-run.sh"; do
    if [ -f "$helper" ]; then
      rm "$helper"
      echo "  - removed $helper"
      REMOVED=true
    fi
  done
done

SQLITE_SHIM="$AGENTS_DIR/bin/sqlite3"
REMOVED_SQLITE_SHIM=false
if [ -f "$SQLITE_SHIM" ] && grep -q "sqlite3 compatibility shim for agmsg" "$SQLITE_SHIM" 2>/dev/null; then
  rm "$SQLITE_SHIM"
  echo "  - removed $SQLITE_SHIM"
  REMOVED=true
  REMOVED_SQLITE_SHIM=true
fi

SQLITE_SHIM_CACHE="$AGENTS_DIR/run/sqlite3-shim.cache"
if [ "$REMOVED_SQLITE_SHIM" = true ] && [ -f "$SQLITE_SHIM_CACHE" ]; then
  rm "$SQLITE_SHIM_CACHE"
  echo "  - removed $SQLITE_SHIM_CACHE"
  REMOVED=true
fi

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
  rmdir "$AGENTS_DIR/bin" 2>/dev/null || true
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
