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

    projects=$(python3 -c "
import json
with open('$config') as f:
    cfg = json.load(f)
for name, info in cfg.get('agents', {}).items():
    if info.get('type') == 'claude-code' and 'project' in info:
        print(info['project'])
" 2>/dev/null || true)

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

      # Remove PostToolUse hook from settings.json
      settings_file="$project/.claude/settings.json"
      if [ -f "$settings_file" ] && grep -q "scripts/inbox.sh" "$settings_file" 2>/dev/null; then
        python3 -c "
import json

with open('$settings_file') as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})
post_hooks = hooks.get('PostToolUse', [])

filtered = [
    h for h in post_hooks
    if not any(
        'scripts/inbox.sh' in hook.get('command', '')
        for hook in h.get('hooks', [])
    )
]

if len(filtered) != len(post_hooks):
    hooks['PostToolUse'] = filtered
    if not filtered:
        del hooks['PostToolUse']
    if not hooks:
        del settings['hooks']
    with open('$settings_file', 'w') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write('\n')
    print('  - removed PostToolUse hook from $settings_file')
" 2>/dev/null || true
        REMOVED=true
      fi
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
    python3 -c "
import re

config_path = '$CODEX_CONFIG'
skill_dirs = [$(printf '"%s",' "${SKILL_DIRS[@]}" | sed 's/,$//')]

with open(config_path) as f:
    content = f.read()

match = re.search(r'writable_roots\s*=\s*\[([^\]]*)\]', content)
if match:
    entries = match.group(1)
    # Parse existing entries
    paths = re.findall(r'\"([^\"]+)\"', entries)
    # Filter out paths belonging to removed skill dirs
    filtered = [p for p in paths if not any(p.startswith(sd) for sd in skill_dirs)]
    if filtered:
        new_val = ', '.join('\"' + p + '\"' for p in filtered)
        content = content[:match.start(1)] + new_val + content[match.end(1):]
    else:
        # Remove entire writable_roots line and empty [sandbox_workspace_write] section
        content = re.sub(r'\n?writable_roots\s*=\s*\[[^\]]*\]\n?', '\n', content)
        content = re.sub(r'\n\[sandbox_workspace_write\]\s*\n(?=\n|\[|$)', '\n', content)

    with open(config_path, 'w') as f:
        f.write(content)
    print('  - cleaned Codex writable_roots (backup: config.toml.bak)')
" 2>/dev/null || true
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
