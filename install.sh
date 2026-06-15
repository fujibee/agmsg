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

# Resolve a provenance version for the source being installed, so an installed
# copy is uniquely identifiable even between tagged releases (the canonical
# VERSION only bumps at release). From a git checkout: `git describe` — tag +
# commits-since + abbreviated commit, plus `-dirty` when the source tree had
# uncommitted changes. Non-git (tarball via setup.sh/npx, no .git): fall back to
# the canonical VERSION file. See #117.
agmsg_source_version() {
  local v top
  # Only describe when SCRIPT_DIR is ITS OWN git checkout. `git describe`
  # searches ancestors for a .git, so a non-git copy unpacked under some other
  # git repo would otherwise record that PARENT repo's describe instead of
  # agmsg's canonical VERSION. Requiring the toplevel to equal SCRIPT_DIR also
  # works for agmsg's own worktrees (install.sh sits at the worktree root).
  top="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ] && [ "$top" = "$SCRIPT_DIR" ] \
      && v="$(git -C "$SCRIPT_DIR" describe --tags --always --dirty --abbrev=7 2>/dev/null)" \
      && [ -n "$v" ]; then
    printf '%s' "$v"
  elif [ -f "$SCRIPT_DIR/VERSION" ]; then
    tr -d '[:space:]' < "$SCRIPT_DIR/VERSION"
  else
    printf 'unknown'
  fi
}

# --- Defaults ---
CMD_NAME=""
UPDATE_ONLY=false
INTERACTIVE=true
AGENT_TYPE=""  # claude-code, codex, gemini, antigravity — passed via --agent-type, or empty for auto/default

is_windows_host() {
  if [ "${AGMSG_FORCE_WINDOWS:-}" = "1" ]; then
    return 0
  fi

  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

install_windows_helpers() {
  if ! is_windows_host; then
    return 0
  fi

  mkdir -p "$AGENTS_DIR/bin"
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$SCRIPT_DIR/scripts/windows/agmsg.ps1" > "$AGENTS_DIR/$CMD_NAME.ps1"
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$SCRIPT_DIR/scripts/windows/agmsg-run.sh" > "$AGENTS_DIR/$CMD_NAME-run.sh"
  cp "$SCRIPT_DIR/scripts/windows/sqlite3-shim.sh" "$AGENTS_DIR/bin/sqlite3"
  chmod +x "$AGENTS_DIR/$CMD_NAME-run.sh" "$AGENTS_DIR/bin/sqlite3"

  # Make the shim available to the rest of this installer run. The generated
  # PowerShell runner also prepends this path for future manual invocations.
  export PATH="$AGENTS_DIR/bin:$PATH"

  echo "  + installed Windows helpers to ~/.agents/"
  echo "    PowerShell shortcut: ~/.agents/$CMD_NAME.ps1"
  echo "    Git Bash runner:     ~/.agents/$CMD_NAME-run.sh"
  echo "    sqlite3 shim:        ~/.agents/bin/sqlite3"
  echo "  ~ To enable the PowerShell shortcut, dot-source it from your profile:"
  echo "    . \"\$HOME\\.agents\\$CMD_NAME.ps1\""
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cmd)    CMD_NAME="$2"; INTERACTIVE=false; shift 2 ;;
    --agent-type) AGENT_TYPE="$2"; shift 2 ;;
    --update) UPDATE_ONLY=true; shift ;;
    -h|--help)
      echo "Usage: ./install.sh [options]"
      echo ""
      echo "Options:"
      echo "  --cmd <name>      Command & skill folder name (default: agmsg)"
      echo "                    Claude Code: /<cmd>, Codex/Gemini/Antigravity: \$<cmd>"
      echo "  --agent-type <t>  Agent type: claude-code, codex, gemini, antigravity"
      echo "                    Selects which template becomes SKILL.md (matches the"
      echo "                    <type> arg passed to join.sh / whoami.sh)"
      echo "  --update          Update skill scripts only (preserve DB and teams)"
      echo ""
      echo "After install, join a team per-project:"
      echo "  ~/.agents/skills/<cmd>/scripts/join.sh <team> <name> <type> <project>"
      echo "  Or just run /<cmd> in Claude Code — it will prompt if not in a team."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Force non-interactive when stdin is not a terminal. Without this, the
# command-name prompt below would call `read -r` on whatever stream is wired
# to fd 0 — which for `curl ... | bash`-style entry paths (e.g. the npm
# bootstrapper before its own fix) is the wrapper script itself, so the
# next line of the wrapper gets consumed as the command name. See #98.
# The `bash <(curl ...)` form in the README is fine because process
# substitution preserves stdin; this guard only kicks in for pipe entries.
if [ ! -t 0 ]; then
  INTERACTIVE=false
fi

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
  CMD_NAME="$SKILL_NAME"
  echo "  Updating $SKILL_NAME..."
  if [ -z "$AGENT_TYPE" ]; then
    if grep -q "whoami.sh.*antigravity" "$SKILL_DIR/SKILL.md" 2>/dev/null; then
      AGENT_TYPE="antigravity"
    elif grep -q "whoami.sh.*gemini" "$SKILL_DIR/SKILL.md" 2>/dev/null; then
      AGENT_TYPE="gemini"
    else
      AGENT_TYPE="codex"
    fi
  fi
  SKILL_TEMPLATE="cmd.codex.md"
  if [ "$AGENT_TYPE" = "gemini" ]; then
    SKILL_TEMPLATE="cmd.gemini.md"
  elif [ "$AGENT_TYPE" = "antigravity" ]; then
    SKILL_TEMPLATE="cmd.antigravity.md"
  fi
  sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$SCRIPT_DIR/templates/$SKILL_TEMPLATE" > "$SKILL_DIR/SKILL.md"
  # Recursive copy so nested helper dirs (scripts/lib/) ship without enumerating files.
  cp -R "$SCRIPT_DIR/scripts/." "$SKILL_DIR/scripts/"
  for tmpl in "$SCRIPT_DIR/templates/"cmd.*.md; do
    sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$tmpl" > "$SKILL_DIR/templates/$(basename "$tmpl")"
  done
  # Refresh the Claude Code slash command file (was missed in earlier --update flows).
  CC_COMMANDS_DIR="$HOME/.claude/commands"
  if [ -d "$CC_COMMANDS_DIR" ] && [ -f "$CC_COMMANDS_DIR/$SKILL_NAME.md" ]; then
    sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$SCRIPT_DIR/templates/cmd.claude-code.md" > "$CC_COMMANDS_DIR/$SKILL_NAME.md"
  fi
  # Refresh / install the Copilot CLI skill (Copilot reads SKILL.md from its
  # own skills dir; the shared ~/.agents/skills/<name>/SKILL.md is
  # Codex-typed and would mis-identify the agent as codex when invoked from
  # Copilot). Same condition as the fresh-install path so users upgrading
  # from a pre-Copilot release via --update also gain the skill.
  COPILOT_SKILL_DIR="$HOME/.copilot/skills/$SKILL_NAME"
  if [ -d "$HOME/.copilot" ]; then
    mkdir -p "$COPILOT_SKILL_DIR"
    sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$SCRIPT_DIR/templates/cmd.copilot.md" > "$COPILOT_SKILL_DIR/SKILL.md"
  fi
  cp "$SCRIPT_DIR/openai.yaml" "$SKILL_DIR/agents/openai.yaml" 2>/dev/null || true
  chmod +x "$SKILL_DIR/scripts/"*.sh
  install_windows_helpers
  INSTALLED_VERSION="$(agmsg_source_version)"
  printf '%s\n' "$INSTALLED_VERSION" > "$SKILL_DIR/VERSION"
  echo "  + updated scripts, templates, and SKILL.md (version $INSTALLED_VERSION)"
  echo "  ~ DB and team configs preserved"
  echo ""
  echo "  ! Restart any running agent sessions to pick up the updated scripts."
  echo "    In-flight watch.sh processes keep the old code until they restart."
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

# SKILL.md is generated from the agent-specific command template.
SKILL_TEMPLATE="cmd.codex.md"
if [ "$AGENT_TYPE" = "gemini" ]; then
  SKILL_TEMPLATE="cmd.gemini.md"
elif [ "$AGENT_TYPE" = "antigravity" ]; then
  SKILL_TEMPLATE="cmd.antigravity.md"
fi
sed "s/__SKILL_NAME__/$CMD_NAME/g" "$SCRIPT_DIR/templates/$SKILL_TEMPLATE" > "$SKILL_DIR/SKILL.md"
# Recursive copy so nested helper dirs (scripts/lib/) ship without enumerating files.
cp -R "$SCRIPT_DIR/scripts/." "$SKILL_DIR/scripts/"

# Replace placeholder in templates with actual skill name
for tmpl in "$SCRIPT_DIR/templates/"cmd.*.md; do
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$tmpl" > "$SKILL_DIR/templates/$(basename "$tmpl")"
done

cp "$SCRIPT_DIR/openai.yaml" "$SKILL_DIR/agents/openai.yaml" 2>/dev/null || true
chmod +x "$SKILL_DIR/scripts/"*.sh
install_windows_helpers

# Marker file for uninstall detection
touch "$SKILL_DIR/.agmsg"

# Record the provenance version of the source we installed from (see #117).
INSTALLED_VERSION="$(agmsg_source_version)"
printf '%s\n' "$INSTALLED_VERSION" > "$SKILL_DIR/VERSION"

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

# --- Install Copilot CLI skill ---
# Copilot loads SKILL.md from ~/.copilot/skills/<name>/. The shared
# ~/.agents/skills/<name>/SKILL.md is Codex-typed (whoami ... codex) and
# would mis-identify a Copilot session — keep the Copilot copy separate.
COPILOT_SKILL_DIR="$HOME/.copilot/skills/$CMD_NAME"
if [ -d "$HOME/.copilot" ]; then
  mkdir -p "$COPILOT_SKILL_DIR"
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$SCRIPT_DIR/templates/cmd.copilot.md" > "$COPILOT_SKILL_DIR/SKILL.md"
  echo "  + installed /$CMD_NAME skill to ~/.copilot/skills/"
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
echo "  ✓ Installed to ~/.agents/skills/$CMD_NAME/ (version $INSTALLED_VERSION)"
echo ""
echo "  Next steps:"
echo "    1. Restart your agent (Claude Code / Codex / Gemini CLI / Antigravity) to pick up the new skill"
echo "    2. Run the command to join a team:"
echo "       Claude Code:  /$CMD_NAME"
echo "       Codex:        \$$CMD_NAME"
echo "       Gemini CLI:   \$$CMD_NAME"
echo "       Antigravity:  \$$CMD_NAME"
echo "       Copilot CLI:  /$CMD_NAME"
echo "       It will prompt for team name and agent name on first run."
echo ""
echo "  Docs: https://agmsg.cc/"
echo ""
