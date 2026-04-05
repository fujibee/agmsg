#!/usr/bin/env bash
set -euo pipefail

# agmsg — Agent Messaging installer
# Installs cross-agent messaging to ~/.agents/skills/<cmd>/
#
# Usage:
#   ./install.sh                    # Interactive (asks command name only)
#   ./install.sh --cmd m            # Non-interactive
#   ./install.sh --update           # Update scripts in place
#
# Options:
#   --cmd <name>        Command & skill folder name (default: agmsg)
#                       Claude Code: /<cmd>, Codex: $<cmd>
#   --update            Update skill scripts only (preserve DB and teams)
#
# Joining a team is done separately per-project, either by:
#   - Running /<cmd> in Claude Code (auto-detects if not in a team)
#   - Running: ~/.agents/skills/<cmd>/scripts/join.sh <team> <name> <type> <project>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$HOME/.agents"

# --- Defaults ---
CMD_NAME=""
UPDATE_ONLY=false
INTERACTIVE=true

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cmd)    CMD_NAME="$2"; INTERACTIVE=false; shift 2 ;;
    --update) UPDATE_ONLY=true; shift ;;
    -h|--help)
      echo "Usage: ./install.sh [options]"
      echo ""
      echo "Options:"
      echo "  --cmd <name>   Command & skill folder name (default: agmsg)"
      echo "                 Claude Code: /<cmd>, Codex: \$<cmd>"
      echo "  --update       Update skill scripts only (preserve DB and teams)"
      echo ""
      echo "After install, join a team per-project:"
      echo "  ~/.agents/skills/<cmd>/scripts/join.sh <team> <name> <type> <project>"
      echo "  Or just run /<cmd> in Claude Code — it will prompt if not in a team."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Check dependencies ---
if ! command -v sqlite3 &>/dev/null; then
  echo "Error: sqlite3 is required but not found." >&2
  echo "  macOS: included by default" >&2
  echo "  Linux: sudo apt install sqlite3  (or equivalent)" >&2
  exit 1
fi

# --- Banner ---
echo ""
echo "  agmsg — Agent Messaging"
echo "  ────────────────────────"
echo ""

# --- Update mode ---
if [ "$UPDATE_ONLY" = true ]; then
  # Find existing install
  SKILL_DIR=""
  for d in "$AGENTS_DIR"/skills/*/; do
    if [ -f "${d}.agmsg" ]; then
      SKILL_DIR="${d%/}"
      break
    fi
  done
  if [ -z "$SKILL_DIR" ]; then
    echo "  ! Not installed. Run ./install.sh first." >&2
    exit 1
  fi
  SKILL_NAME="$(basename "$SKILL_DIR")"
  echo "  Updating $SKILL_NAME..."
  sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$SCRIPT_DIR/templates/cmd.codex.md" > "$SKILL_DIR/SKILL.md"
  cp "$SCRIPT_DIR/scripts/"*.sh "$SKILL_DIR/scripts/"
  for tmpl in "$SCRIPT_DIR/templates/"cmd.*.md; do
    sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$tmpl" > "$SKILL_DIR/templates/$(basename "$tmpl")"
  done
  cp "$SCRIPT_DIR/openai.yaml" "$SKILL_DIR/agents/openai.yaml" 2>/dev/null || true
  chmod +x "$SKILL_DIR/scripts/"*.sh
  echo "  + updated scripts, templates, and SKILL.md"
  echo "  ~ DB and team configs preserved"
  echo ""
  echo "  ✓ Update complete"
  echo ""
  exit 0
fi

# --- Interactive mode ---
if [ "$INTERACTIVE" = true ]; then
  printf "  Command name [agmsg]: "
  read -r input
  CMD_NAME="${input:-agmsg}"
  echo ""

fi

# --- Apply defaults ---
CMD_NAME="${CMD_NAME:-agmsg}"
SKILL_DIR="$AGENTS_DIR/skills/$CMD_NAME"

# --- Install skill ---
echo "  Installing to ~/.agents/skills/$CMD_NAME/ ..."
mkdir -p "$SKILL_DIR"/{scripts,templates,db,agents}

# SKILL.md is generated from the Codex command template (Codex reads SKILL.md directly)
sed "s/__SKILL_NAME__/$CMD_NAME/g" "$SCRIPT_DIR/templates/cmd.codex.md" > "$SKILL_DIR/SKILL.md"
cp "$SCRIPT_DIR/scripts/"*.sh "$SKILL_DIR/scripts/"

# Replace placeholder in templates with actual skill name
for tmpl in "$SCRIPT_DIR/templates/"cmd.*.md; do
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$tmpl" > "$SKILL_DIR/templates/$(basename "$tmpl")"
done

cp "$SCRIPT_DIR/openai.yaml" "$SKILL_DIR/agents/openai.yaml" 2>/dev/null || true
chmod +x "$SKILL_DIR/scripts/"*.sh

# Marker file for uninstall detection
touch "$SKILL_DIR/.agmsg"

# Initialize DB
if [ ! -f "$SKILL_DIR/db/messages.db" ]; then
  bash "$SKILL_DIR/scripts/init-db.sh"
fi

# Initialize config
if [ ! -f "$SKILL_DIR/db/config.yaml" ]; then
  bash "$SKILL_DIR/scripts/config.sh" show >/dev/null
  echo "  + created default config at db/config.yaml"
fi

# --- Install Claude Code global command ---
CC_COMMANDS_DIR="$HOME/.claude/commands"
if [ -d "$HOME/.claude" ]; then
  mkdir -p "$CC_COMMANDS_DIR"
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$SCRIPT_DIR/templates/cmd.claude-code.md" > "$CC_COMMANDS_DIR/$CMD_NAME.md"
  echo "  + installed /$CMD_NAME command to ~/.claude/commands/"
fi

# --- Configure Codex sandbox (if Codex is installed) ---
CODEX_CONFIG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CONFIG" ]; then
  WRITABLE_PATHS=("$SKILL_DIR/db" "$SKILL_DIR/teams")
  missing=()
  for p in "${WRITABLE_PATHS[@]}"; do
    if ! grep -q "$p" "$CODEX_CONFIG" 2>/dev/null; then
      missing+=("$p")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    echo "  ~ Codex writable_roots already configured"
  else
    cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak"
    echo "  ~ backed up $CODEX_CONFIG → $CODEX_CONFIG.bak"

    # Build entries string: "path1", "path2"
    entries=$(printf ', "%s"' "${missing[@]}")
    entries="${entries:2}"  # remove leading ", "

    if grep -q 'writable_roots' "$CODEX_CONFIG" 2>/dev/null; then
      # Append to existing writable_roots (handles multiline arrays)
      awk -v new_entries="$entries" '
        /writable_roots/ { in_roots=1 }
        in_roots && /\]/ {
          sub(/\]/, ", " new_entries "]")
          in_roots=0
        }
        { print }
      ' "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp" && mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
    elif grep -q '^\[sandbox_workspace_write\]' "$CODEX_CONFIG" 2>/dev/null; then
      # Section exists but no writable_roots
      awk -v entries="$entries" '
        { print }
        /^\[sandbox_workspace_write\]/ { print "writable_roots = [" entries "]" }
      ' "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp" && mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
    else
      # No section at all
      printf '\n[sandbox_workspace_write]\nwritable_roots = [%s]\n' "$entries" >> "$CODEX_CONFIG"
    fi
    echo "  + added Codex writable_roots for db/ and teams/"
  fi
fi

# --- Done ---
echo ""
echo "  ✓ Installed to ~/.agents/skills/$CMD_NAME/"
echo ""
echo "  Next steps:"
echo "    1. Restart your agent (Claude Code / Codex) to pick up the new skill"
echo "    2. Run the command to join a team:"
echo "       Claude Code:  /$CMD_NAME"
echo "       Codex:        \$$CMD_NAME"
echo "       It will prompt for team name and agent name on first run."
echo ""
