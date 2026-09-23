#!/usr/bin/env bash
set -euo pipefail

# agmsg — Agent Messaging uninstaller
# With no options, removes ONE install's own messaging skill, commands, and
# hooks (#1400: this used to remove every agmsg install found on the
# machine, unconditionally). --all restores that "remove everything" shape,
# but only when explicitly asked for.
#
# Usage:
#   ./uninstall.sh                    # This install only (confirms each step)
#   ./uninstall.sh --yes              # This install only, no confirmation
#   ./uninstall.sh --keep-data        # Remove skill but keep DB and teams
#   ./uninstall.sh --all              # Every agmsg install on the machine
#                                     # (one combined confirmation, unless --yes)

AGENTS_DIR="$HOME/.agents"

AUTO_YES=false
KEEP_DATA=false
REMOVE_ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)       AUTO_YES=true;  shift ;;
    --keep-data)    KEEP_DATA=true; shift ;;
    --all)          REMOVE_ALL=true; shift ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [options]"
      echo ""
      echo "Options:"
      echo "  --yes, -y       Remove without confirmation"
      echo "  --keep-data     Remove skill but keep DB and team configs"
      echo "  --all           Remove every agmsg install on the machine"
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

REMOVED=false

# Removes ONE install's own commands, hooks, skill files, and Codex
# writable_roots entries -- everything except the machine-wide shared
# pieces, which the caller handles once, separately (_uninstall_shared_pieces
# below). Sets the global REMOVED=true on any change.
_uninstall_one() {
  local SKILL_DIR="$1"
  local SKILL_NAME; SKILL_NAME="$(basename "$SKILL_DIR")"

  # --- Remove slash commands and hooks from joined projects ---
  local TEAMS_DIR="$SKILL_DIR/teams"
  if [ -d "$TEAMS_DIR" ]; then
    echo "  Scanning joined projects for commands and hooks..."
    local config
    for config in "$TEAMS_DIR"/*/config.json; do
      [ -f "$config" ] || continue

      local projects
      projects=$(sqlite3 -separator '	' :memory: \
        ".param set :json '$(sed "s/'/''/g" "$config")'" \
        "SELECT json_extract(value, '$.project') FROM json_each(json_extract(:json, '$.agents'))
         WHERE json_extract(value, '$.type') = 'claude-code'
           AND json_extract(value, '$.project') IS NOT NULL;" 2>/dev/null || true)

      local project
      while IFS= read -r project; do
        [ -n "$project" ] || continue

        # Remove command files that reference agmsg scripts
        if [ -d "$project/.claude/commands" ]; then
          local cmd_file
          for cmd_file in "$project/.claude/commands"/*.md; do
            [ -f "$cmd_file" ] || continue
            if grep -q "scripts/whoami.sh\|scripts/inbox.sh\|scripts/send.sh" "$cmd_file" 2>/dev/null; then
              local cmd_name; cmd_name=$(basename "$cmd_file" .md)
              rm "$cmd_file"
              echo "  - removed /$cmd_name command from $project"
              REMOVED=true
            fi
          done
        fi

        # Remove only agmsg hook entries from settings files (preserve other hooks)
        local settings_file
        for settings_file in "$project/.claude/settings.json" "$project/.claude/settings.local.json"; do
          if [ -f "$settings_file" ] && grep -q "$SKILL_NAME" "$settings_file" 2>/dev/null; then
            local SETTINGS_ESC UPDATED
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
      local copilot_projects
      copilot_projects=$(sqlite3 -separator '	' :memory: \
        ".param set :json '$(sed "s/'/''/g" "$config")'" \
        "SELECT json_extract(value, '$.project') FROM json_each(json_extract(:json, '$.agents'))
         WHERE json_extract(value, '$.type') = 'copilot'
           AND json_extract(value, '$.project') IS NOT NULL;" 2>/dev/null || true)

      while IFS= read -r project; do
        [ -n "$project" ] || continue
        local copilot_hook="$project/.github/hooks/agmsg.json"
        if [ -f "$copilot_hook" ] && grep -q "$SKILL_NAME" "$copilot_hook" 2>/dev/null; then
          rm "$copilot_hook"
          echo "  - removed agmsg Copilot hook from $project"
          REMOVED=true
        fi
      done <<< "$copilot_projects"
    done
  fi

  # --- Remove Claude Code global command ---
  local CC_CMD="$HOME/.claude/commands/$SKILL_NAME.md"
  if [ -f "$CC_CMD" ]; then
    rm "$CC_CMD"
    echo "  - removed /$SKILL_NAME from ~/.claude/commands/"
    REMOVED=true
  fi

  # --- Remove Copilot CLI skill ---
  local COPILOT_SKILL="$HOME/.copilot/skills/$SKILL_NAME"
  if [ -d "$COPILOT_SKILL" ]; then
    rm -rf "$COPILOT_SKILL"
    echo "  - removed /$SKILL_NAME skill from ~/.copilot/skills/"
    REMOVED=true
  fi

  # --- Remove Antigravity skill ---
  local ANTIGRAVITY_SKILL="$HOME/.gemini/config/skills/$SKILL_NAME"
  if [ -d "$ANTIGRAVITY_SKILL" ]; then
    rm -rf "$ANTIGRAVITY_SKILL"
    echo "  - removed /$SKILL_NAME skill from ~/.gemini/config/skills/"
    REMOVED=true
  fi

  # --- Remove native Windows helpers ---
  local helper
  for helper in "$AGENTS_DIR/$SKILL_NAME.ps1" "$AGENTS_DIR/$SKILL_NAME-run.sh"; do
    if [ -f "$helper" ]; then
      rm "$helper"
      echo "  - removed $helper"
      REMOVED=true
    fi
  done

  # --- Remove the skill directory ---
  if [ "$KEEP_DATA" = true ]; then
    echo ""
    echo "  Removing $SKILL_NAME skill (keeping DB and teams)..."
    rm -rf "$SKILL_DIR/scripts" "$SKILL_DIR/templates" "$SKILL_DIR/agents" "$SKILL_DIR/.trash"
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

  # --- Clean up Codex writable_roots (this install's own path only) ---
  local CODEX_CONFIG="$HOME/.codex/config.toml"
  if [ -f "$CODEX_CONFIG" ] && grep -q "$SKILL_DIR" "$CODEX_CONFIG" 2>/dev/null; then
    cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak"
    local skill_pattern="$SKILL_DIR"

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
}

# Machine-wide pieces, shared by every install: only safe to remove once NO
# agmsg install remains on the machine to still need them. Sets the global
# REMOVED=true on any change.
_uninstall_shared_pieces() {
  local SQLITE_SHIM="$AGENTS_DIR/bin/sqlite3"
  local REMOVED_SQLITE_SHIM=false
  if [ -f "$SQLITE_SHIM" ] && grep -q "sqlite3 compatibility shim for agmsg" "$SQLITE_SHIM" 2>/dev/null; then
    rm "$SQLITE_SHIM"
    echo "  - removed $SQLITE_SHIM"
    REMOVED=true
    REMOVED_SQLITE_SHIM=true
  fi

  local SQLITE_SHIM_CACHE="$AGENTS_DIR/run/sqlite3-shim.cache"
  if [ "$REMOVED_SQLITE_SHIM" = true ] && [ -f "$SQLITE_SHIM_CACHE" ]; then
    rm "$SQLITE_SHIM_CACHE"
    echo "  - removed $SQLITE_SHIM_CACHE"
    REMOVED=true
  fi

  # A same-named non-agmsg file is left alone -- the owner-comment signature
  # is what confirms this is genuinely an agmsg-written shim, not who wrote
  # it: with no install left, whichever one wrote it no longer matters.
  local ANTIGRAVITY_TUI_SHIM="$AGENTS_DIR/bin/agy-tui"
  if [ -f "$ANTIGRAVITY_TUI_SHIM" ] && grep -q "^# agmsg-shim-owner: " "$ANTIGRAVITY_TUI_SHIM" 2>/dev/null; then
    rm "$ANTIGRAVITY_TUI_SHIM"
    echo "  - removed $ANTIGRAVITY_TUI_SHIM"
    REMOVED=true
  fi
}

if [ "$REMOVE_ALL" = true ]; then
  # --- --all: every agmsg install on the machine (#1400 follow-up) ---
  # The pre-fix behavior, restored, but only when explicitly asked for --
  # works the same no matter which install's uninstall.sh (or a repo
  # checkout's ./uninstall.sh) this is run from, since it enumerates every
  # marker unconditionally rather than resolving one.
  ALL_SKILL_DIRS=()
  for d in "$AGENTS_DIR"/skills/*/; do
    d="${d%/}"
    [ -f "$d/.agmsg" ] && ALL_SKILL_DIRS+=("$d")
  done

  if [ ${#ALL_SKILL_DIRS[@]} -eq 0 ]; then
    echo "  Nothing to remove (not installed?)"
    echo ""
    exit 0
  fi

  echo "  Removing ALL installations:"
  for d in "${ALL_SKILL_DIRS[@]}"; do
    echo "    $(basename "$d") → $d"
  done
  echo ""

  if [ "$AUTO_YES" != true ]; then
    if ! confirm "Remove ALL ${#ALL_SKILL_DIRS[@]} installation(s) listed above?"; then
      echo "  Aborted."
      echo ""
      exit 0
    fi
    # One combined confirmation covers the whole run: the per-install "keep
    # DB and teams?" prompt inside _uninstall_one must not ask again, once
    # per install, for a question this already answered.
    AUTO_YES=true
  fi

  for d in "${ALL_SKILL_DIRS[@]}"; do
    echo ""
    echo "  --- $(basename "$d") ---"
    _uninstall_one "$d"
  done

  echo ""
  _uninstall_shared_pieces

else
  # --- This install only (#1400) ---
  #
  # Earlier this iterated every ~/.agents/skills/*/ carrying an `.agmsg`
  # marker -- every OTHER install on the machine, not just this one -- and
  # removed all of their commands, skills, hooks and writable_roots entries:
  # uninstalling one throwaway install wiped every install on the machine.
  # Deciding which ONE install this run is about, in order:
  #   1. uninstall.sh ships INSIDE each install (copied there by install.sh)
  #      and is normally run from there, so when $0's own directory carries
  #      the marker, that unambiguously IS this run's install.
  #   2. $0 does not identify one (e.g. run from a kept git checkout, the way
  #      this project's own tests do): a single install on the machine is
  #      still unambiguous. More than one refuses rather than guess --
  #      pointing at each one's own uninstall.sh, or --all to remove every
  #      install on the machine at once.
  SELF_SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ ! -f "$SELF_SKILL_DIR/.agmsg" ]; then
    candidates=()
    for d in "$AGENTS_DIR"/skills/*/; do
      d="${d%/}"
      [ -f "$d/.agmsg" ] && candidates+=("$d")
    done
    case "${#candidates[@]}" in
      0)
        echo "  Nothing to remove (not installed?)"
        echo ""
        exit 0
        ;;
      1) SELF_SKILL_DIR="${candidates[0]}" ;;
      *)
        echo "  ! Several agmsg installs found:" >&2
        for d in "${candidates[@]}"; do
          echo "      $d/uninstall.sh" >&2
        done
        echo "  ! Cannot tell which one to uninstall. Run the uninstall.sh inside the one you want to remove, or pass --all to remove them all." >&2
        exit 1
        ;;
    esac
  fi

  # Other installs, purely to decide whether the machine-wide shared pieces
  # are still needed below -- never touched otherwise. Two installs can
  # legitimately coexist (different --cmd names to install.sh), and one
  # going away must not disturb the others.
  OTHER_SKILL_DIRS=()
  for d in "$AGENTS_DIR"/skills/*/; do
    [ -f "${d}.agmsg" ] || continue
    [ "${d%/}" = "$SELF_SKILL_DIR" ] && continue
    OTHER_SKILL_DIRS+=("${d%/}")
  done

  echo "  Removing installation:"
  echo "    $(basename "$SELF_SKILL_DIR") → $SELF_SKILL_DIR"
  if [ ${#OTHER_SKILL_DIRS[@]} -gt 0 ]; then
    echo "  Other installation(s) found, left untouched:"
    for sd in "${OTHER_SKILL_DIRS[@]}"; do
      echo "    $(basename "$sd") → $sd"
    done
  fi
  echo ""

  _uninstall_one "$SELF_SKILL_DIR"

  if [ ${#OTHER_SKILL_DIRS[@]} -eq 0 ]; then
    _uninstall_shared_pieces
  fi
fi

# --- Clean up empty ~/.agents/ ---
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
