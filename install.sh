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

# Type registry — resolve each type's SKILL command template from its manifest
# (scripts/drivers/types/<name>/template.md) instead of a hardcoded templates/ path. Read-only
# helpers; safe to source.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/scripts/lib/type-registry.sh"

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

configure_codex_sandbox() {
  # --- Configure Codex sandbox (if Codex is installed) ---
  # The Codex bridge (beta) writes pidfiles/sockets/request files under the
  # skill's db/, teams/, run/ dirs; Codex's sandbox blocks those writes unless
  # they are listed as writable_roots. See docs/codex-monitor-beta.md.
  local code_config="$HOME/.codex/config.toml"
  if [ ! -f "$code_config" ]; then
    return 0
  fi

  local writable_paths=("$SKILL_DIR/db" "$SKILL_DIR/teams" "$SKILL_DIR/run")
  # On Windows (MSYS2/Git Bash), $SKILL_DIR is in MSYS form (/c/Users/...).
  # Codex is a native Windows binary whose Rust path resolution cannot parse
  # MSYS paths — /c/Users/... is resolved to C:\c\Users\... (a phantom path).
  # Convert to the mixed C:/Users/... form that both the shell and Codex accept.
  if command -v cygpath >/dev/null 2>&1; then
    local i
    for i in "${!writable_paths[@]}"; do
      writable_paths[$i]="$(cygpath -m "${writable_paths[$i]}" 2>/dev/null || printf '%s' "${writable_paths[$i]}")"
    done
  fi
  local missing=()
  local p
  for p in "${writable_paths[@]}"; do
    if ! grep -q "$p" "$code_config" 2>/dev/null; then
      missing+=("$p")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    echo "  ~ Codex writable_roots already configured"
    return 0
  fi

  cp "$code_config" "$code_config.bak"
  echo "  ~ backed up $code_config → $code_config.bak"

  local entries inserts
  entries=$(printf ', "%s"' "${missing[@]}")
  entries="${entries:2}"  # remove leading ", " — for the "create a new array" branches
  inserts=$(printf '"%s", ' "${missing[@]}")  # trailing ", " — prepended inside an existing array

  if grep -q 'writable_roots' "$code_config" 2>/dev/null; then
    # Insert into the existing array right after its opening '['. This is
    # uniformly valid TOML for empty ([]), single-line and multiline arrays —
    # trailing commas are legal — and avoids the leading/double-comma corruption
    # that munging the closing ']' produced for an empty array (`[, "x"]`).
    awk -v ins="$inserts" '
      !done && /writable_roots[[:space:]]*=[[:space:]]*\[/ {
        sub(/\[/, "[" ins)
        done=1
      }
      { print }
    ' "$code_config" > "$code_config.tmp" && mv "$code_config.tmp" "$code_config"
  elif grep -q '^\[sandbox_workspace_write\]' "$code_config" 2>/dev/null; then
    # Section exists but no writable_roots
    awk -v entries="$entries" '
      { print }
      /^\[sandbox_workspace_write\]/ { print "writable_roots = [" entries "]" }
    ' "$code_config" > "$code_config.tmp" && mv "$code_config.tmp" "$code_config"
  else
    # No section at all
    printf '\n[sandbox_workspace_write]\nwritable_roots = [%s]\n' "$entries" >> "$code_config"
  fi
  echo "  + added Codex writable_roots for db/, teams/, and run/"
}

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

  mkdir -p "$AGENTS_DIR"

  # Clean up legacy helpers created by the earlier native-Windows approaches.
  local ps_shortcut="$AGENTS_DIR/$CMD_NAME.ps1"
  if [ -f "$ps_shortcut" ] && grep -q "PowerShell shortcut for agmsg on native Windows" "$ps_shortcut" 2>/dev/null; then
    rm -f "$ps_shortcut"
  fi
  rm -f "$AGENTS_DIR/$CMD_NAME-run.sh"
  local sqlite_shim="$AGENTS_DIR/bin/sqlite3"
  local removed_sqlite_shim=false
  if [ -f "$sqlite_shim" ] && grep -q "sqlite3 compatibility shim for agmsg" "$sqlite_shim" 2>/dev/null; then
    rm -f "$sqlite_shim"
    removed_sqlite_shim=true
  fi
  if [ "$removed_sqlite_shim" = true ]; then
    rm -f "$AGENTS_DIR/run/sqlite3-shim.cache"
  fi
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
      echo "  --agent-type <t>  Agent type: claude-code, codex, gemini, antigravity, opencode, hermes, cursor, grok-build"
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
  # Find existing install. If --cmd was passed, update exactly that skill;
  # otherwise preserve the historical "first installed agmsg skill" behavior.
  if [ -n "$CMD_NAME" ]; then
    SKILL_DIR="$AGENTS_DIR/skills/$CMD_NAME"
    if [ ! -f "$SKILL_DIR/.agmsg" ]; then
      echo "  ! Not installed: ~/.agents/skills/$CMD_NAME. Run ./install.sh --cmd $CMD_NAME first." >&2
      exit 1
    fi
  else
    SKILL_DIR=""
    for d in "$AGENTS_DIR"/skills/*/; do
      if [ -f "${d}.agmsg" ]; then
        SKILL_DIR="${d%/}"
        break
      fi
    done
  fi
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
    elif grep -q "whoami.sh.*grok-build" "$SKILL_DIR/SKILL.md" 2>/dev/null; then
      AGENT_TYPE="grok-build"
    else
      AGENT_TYPE="codex"
    fi
  fi
  # The shared SKILL.md uses the codex template by default; gemini/antigravity/
  # opencode get their own. (claude-code and copilot reuse the codex-typed
  # shared SKILL.md; their dedicated copies are dropped separately below.)
  TPL_TYPE="codex"
  case "$AGENT_TYPE" in
    gemini|antigravity|opencode|hermes|cursor|grok-build) TPL_TYPE="$AGENT_TYPE" ;;
  esac
  sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$(agmsg_type_template_path "$TPL_TYPE")" > "$SKILL_DIR/SKILL.md"
  # Recursive copy so nested helper dirs (scripts/lib/, scripts/drivers/types/)
  # ship without enumerating files. The agent-type manifests and per-type runtimes
  # live under scripts/drivers/types/ now, so this single copy carries them too.
  cp -R "$SCRIPT_DIR/scripts/." "$SKILL_DIR/scripts/"
  # Ship the external-plugin drop-in dir (just its README) so the location exists
  # post-install. A plain cp — not cp -R --delete — preserves any plugins the
  # user dropped in and their db/trusted-plugins opt-ins.
  mkdir -p "$SKILL_DIR/plugins"
  cp "$SCRIPT_DIR/plugins/README.md" "$SKILL_DIR/plugins/README.md" 2>/dev/null || true
  # Ship uninstall.sh alongside the skill itself — npx/curl installs fetch a
  # temp checkout that gets deleted right after install, so without this copy
  # those users would have no local uninstaller to run later (only a manual
  # `git clone` checkout would). See the README's Uninstall section.
  cp "$SCRIPT_DIR/uninstall.sh" "$SKILL_DIR/uninstall.sh" 2>/dev/null && chmod +x "$SKILL_DIR/uninstall.sh" || true
  # Refresh the Claude Code slash command file (was missed in earlier --update flows).
  CC_COMMANDS_DIR="$HOME/.claude/commands"
  if [ -d "$CC_COMMANDS_DIR" ] && [ -f "$CC_COMMANDS_DIR/$SKILL_NAME.md" ]; then
    sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$(agmsg_type_template_path claude-code)" > "$CC_COMMANDS_DIR/$SKILL_NAME.md"
  fi
  # Refresh / install the Copilot CLI skill (Copilot reads SKILL.md from its
  # own skills dir; the shared ~/.agents/skills/<name>/SKILL.md is
  # Codex-typed and would mis-identify the agent as codex when invoked from
  # Copilot). Same condition as the fresh-install path so users upgrading
  # from a pre-Copilot release via --update also gain the skill.
  COPILOT_SKILL_DIR="$HOME/.copilot/skills/$SKILL_NAME"
  if [ -d "$HOME/.copilot" ]; then
    mkdir -p "$COPILOT_SKILL_DIR"
    sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$(agmsg_type_template_path copilot)" > "$COPILOT_SKILL_DIR/SKILL.md"
  fi
  # Refresh / install the OpenCode skill (same reasoning as Copilot above).
  OPENCODE_SKILL_DIR="$HOME/.config/opencode/skills/$SKILL_NAME"
  if [ -d "$HOME/.config/opencode" ]; then
    mkdir -p "$OPENCODE_SKILL_DIR"
    sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$(agmsg_type_template_path opencode)" > "$OPENCODE_SKILL_DIR/SKILL.md"
  fi
  # Refresh / install the Hermes Agent skill (same reasoning as Copilot above).
  HERMES_SKILL_DIR="$HOME/.hermes/skills/$SKILL_NAME"
  if [ -d "$HOME/.hermes" ]; then
    mkdir -p "$HERMES_SKILL_DIR"
    sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$(agmsg_type_template_path hermes)" > "$HERMES_SKILL_DIR/SKILL.md"
  fi
  # Refresh / install the Grok Build skill (same reasoning as Copilot above).
  GROK_SKILL_DIR="$HOME/.grok/skills/$SKILL_NAME"
  if [ -d "$HOME/.grok" ]; then
    mkdir -p "$GROK_SKILL_DIR"
    sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$(agmsg_type_template_path grok-build)" > "$GROK_SKILL_DIR/SKILL.md"
  fi
  cp "$SCRIPT_DIR/openai.yaml" "$SKILL_DIR/agents/openai.yaml" 2>/dev/null || true
  chmod +x "$SKILL_DIR/scripts/"*.sh
  chmod +x "$SKILL_DIR/scripts/drivers/types/codex/"*.sh 2>/dev/null || true
  # Refresh the Codex monitor shim (~/.agents/bin/codex) if it's ours. --update
  # cp's the new codex-shim-install.sh but does not re-run it, so a shim from an
  # older install keeps its stale baked exec path after the
  # types/ -> scripts/drivers/types/ move. Re-running install regenerates it with
  # the new path; install is idempotent and overwrites only an agmsg shim (a
  # user's own codex binary fails is_agmsg_shim and is left untouched).
  CODEX_SHIM="$SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh"
  if [ -x "$CODEX_SHIM" ] && AGMSG_CODEX_SHIM_INSTALL_QUIET=1 "$CODEX_SHIM" status 2>/dev/null | grep -q '^installed:'; then
    AGMSG_CODEX_SHIM_INSTALL_QUIET=1 "$CODEX_SHIM" install >/dev/null 2>&1 \
      && echo "  + refreshed Codex monitor shim (~/.agents/bin/codex)"
  fi
  install_windows_helpers
  INSTALLED_VERSION="$(agmsg_source_version)"
  printf '%s\n' "$INSTALLED_VERSION" > "$SKILL_DIR/VERSION"
  echo "  + updated scripts, templates, and SKILL.md (version $INSTALLED_VERSION)"
  echo "  ~ DB and team configs preserved"
  configure_codex_sandbox
  echo ""
  echo "  ! Restart any running agent sessions to pick up the updated scripts."
  echo "    In-flight watch.sh processes keep the old code until they restart."
  echo ""
  echo "  ! If a project uses 'monitor'/'both'/'turn' delivery, re-run"
  echo "    'delivery.sh set <mode> <type> <project>' there. An upgrade (or a skill"
  echo "    manager that rewrites settings) can drop the SessionStart/Stop hook from"
  echo "    a project's settings, silently stopping delivery until it is re-registered."
  echo "    Check with 'delivery.sh status <type> <project>'. (#133)"
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
mkdir -p "$SKILL_DIR"/{scripts,types,db,agents}

# SKILL.md is generated from the agent-specific command template, resolved from
# the type manifest (scripts/drivers/types/<type>/template.md). The shared SKILL.md uses the
# codex template by default; gemini/antigravity/opencode get their own.
TPL_TYPE="codex"
case "$AGENT_TYPE" in
  gemini|antigravity|opencode|hermes|cursor|grok-build) TPL_TYPE="$AGENT_TYPE" ;;
esac
sed "s/__SKILL_NAME__/$CMD_NAME/g" "$(agmsg_type_template_path "$TPL_TYPE")" > "$SKILL_DIR/SKILL.md"
# Recursive copy so nested helper dirs (scripts/lib/, scripts/drivers/types/) ship
# without enumerating files. The agent-type manifests and per-type runtimes live
# under scripts/drivers/types/ now, so this single copy carries them too.
cp -R "$SCRIPT_DIR/scripts/." "$SKILL_DIR/scripts/"
# Ship the external-plugin drop-in dir (just its README) so the location exists
# post-install. A plain cp — not cp -R --delete — preserves any plugins the user
# dropped in and their db/trusted-plugins opt-ins.
mkdir -p "$SKILL_DIR/plugins"
cp "$SCRIPT_DIR/plugins/README.md" "$SKILL_DIR/plugins/README.md" 2>/dev/null || true
# Ship uninstall.sh alongside the skill itself — npx/curl installs fetch a
# temp checkout that gets deleted right after install, so without this copy
# those users would have no local uninstaller to run later (only a manual
# `git clone` checkout would). See the README's Uninstall section.
cp "$SCRIPT_DIR/uninstall.sh" "$SKILL_DIR/uninstall.sh" 2>/dev/null && chmod +x "$SKILL_DIR/uninstall.sh" || true

cp "$SCRIPT_DIR/openai.yaml" "$SKILL_DIR/agents/openai.yaml" 2>/dev/null || true
chmod +x "$SKILL_DIR/scripts/"*.sh
chmod +x "$SKILL_DIR/scripts/drivers/types/codex/"*.sh 2>/dev/null || true
# Re-point an existing Codex monitor shim at the new path on a reinstall over an
# older layout (no-op when no agmsg shim is present). See the --update block above.
CODEX_SHIM="$SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh"
if [ -x "$CODEX_SHIM" ] && AGMSG_CODEX_SHIM_INSTALL_QUIET=1 "$CODEX_SHIM" status 2>/dev/null | grep -q '^installed:'; then
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 "$CODEX_SHIM" install >/dev/null 2>&1 \
    && echo "  + refreshed Codex monitor shim (~/.agents/bin/codex)"
fi
install_windows_helpers

# Marker file for uninstall detection
touch "$SKILL_DIR/.agmsg"

# Record the provenance version of the source we installed from (see #117).
INSTALLED_VERSION="$(agmsg_source_version)"
printf '%s\n' "$INSTALLED_VERSION" > "$SKILL_DIR/VERSION"

# Initialize DB
if [ ! -f "$SKILL_DIR/db/messages.db" ]; then
  bash "$SKILL_DIR/scripts/internal/init-db.sh"
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
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$(agmsg_type_template_path claude-code)" > "$CC_COMMANDS_DIR/$CMD_NAME.md"
  echo "  + installed /$CMD_NAME command to ~/.claude/commands/"
fi

# --- Install Copilot CLI skill ---
# Copilot loads SKILL.md from ~/.copilot/skills/<name>/. The shared
# ~/.agents/skills/<name>/SKILL.md is Codex-typed (whoami ... codex) and
# would mis-identify a Copilot session — keep the Copilot copy separate.
COPILOT_SKILL_DIR="$HOME/.copilot/skills/$CMD_NAME"
if [ -d "$HOME/.copilot" ]; then
  mkdir -p "$COPILOT_SKILL_DIR"
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$(agmsg_type_template_path copilot)" > "$COPILOT_SKILL_DIR/SKILL.md"
  echo "  + installed /$CMD_NAME skill to ~/.copilot/skills/"
fi

# --- Install OpenCode skill ---
# OpenCode reads skills from ~/.config/opencode/skills/<name>/SKILL.md as its
# global config path. The shared ~/.agents/skills/<name>/SKILL.md is
# Codex-typed and would mis-identify an OpenCode session — keep the OpenCode
# copy separate, same pattern as Copilot.
OPENCODE_SKILL_DIR="$HOME/.config/opencode/skills/$CMD_NAME"
if [ -d "$HOME/.config/opencode" ]; then
  mkdir -p "$OPENCODE_SKILL_DIR"
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$(agmsg_type_template_path opencode)" > "$OPENCODE_SKILL_DIR/SKILL.md"
  echo "  + installed \$$CMD_NAME skill to ~/.config/opencode/skills/"
fi

# --- Install Hermes Agent skill ---
# Hermes reads skills from ~/.hermes/skills/<name>/SKILL.md. Runtime scripts and
# the shared SQLite store stay in ~/.agents/skills/<name>/ so Hermes shares the
# same message floor as the other agents. Hermes has no automatic delivery hook
# (manual inbox checks only), but the skill itself installs the same way.
HERMES_SKILL_DIR="$HOME/.hermes/skills/$CMD_NAME"
if [ -d "$HOME/.hermes" ]; then
  mkdir -p "$HERMES_SKILL_DIR"
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$(agmsg_type_template_path hermes)" > "$HERMES_SKILL_DIR/SKILL.md"
  echo "  + installed /$CMD_NAME skill to ~/.hermes/skills/"
fi

# --- Install Grok Build skill ---
# Grok Build reads skills from ~/.grok/skills/<name>/SKILL.md (it also accepts
# the cross-vendor ~/.agents/skills/ fallback, but the shared SKILL.md is
# Codex-typed and would mis-identify a Grok session — keep the Grok copy
# separate, same pattern as Copilot). Delivery (turn) registers a Stop hook under
# ~/.grok/hooks/ via `delivery.sh set` per project.
GROK_SKILL_DIR="$HOME/.grok/skills/$CMD_NAME"
if [ -d "$HOME/.grok" ]; then
  mkdir -p "$GROK_SKILL_DIR"
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$(agmsg_type_template_path grok-build)" > "$GROK_SKILL_DIR/SKILL.md"
  echo "  + installed /$CMD_NAME skill to ~/.grok/skills/"
fi

# Codex sandbox writable_roots are configured by configure_codex_sandbox() at
# the "Done" step below — the single source of truth for db/, teams/, and run/.
# (A legacy inline copy used to run here too, which double-mutated the array and
# produced invalid TOML on a fresh install; it has been removed.)

# --- Done ---
configure_codex_sandbox
echo ""
echo "  ✓ Installed to ~/.agents/skills/$CMD_NAME/ (version $INSTALLED_VERSION)"
echo ""
echo "  Next steps:"
echo "    1. Restart your agent (Claude Code / Codex / Gemini CLI / Antigravity / OpenCode) to pick up the new skill"
echo "    2. Run the command to join a team:"
echo "       Claude Code:  /$CMD_NAME"
echo "       Codex:        \$$CMD_NAME"
echo "       Gemini CLI:   \$$CMD_NAME"
echo "       Antigravity:  \$$CMD_NAME"
echo "       Copilot CLI:  /$CMD_NAME"
echo "       OpenCode:     \$$CMD_NAME"
echo "       It will prompt for team name and agent name on first run."
echo ""
echo "  Docs: https://agmsg.cc/"
echo ""
