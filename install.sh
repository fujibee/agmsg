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
  local v top native
  # Only describe when SCRIPT_DIR is ITS OWN git checkout. `git describe`
  # searches ancestors for a .git, so a non-git copy unpacked under some other
  # git repo would otherwise record that PARENT repo's describe instead of
  # agmsg's canonical VERSION. Requiring the toplevel to equal SCRIPT_DIR also
  # works for agmsg's own worktrees (install.sh sits at the worktree root).
  #
  # --match "v[0-9]*" restricts `describe` to core release tags (v1.1.8, ...);
  # unrestricted --tags also matches the co-located app-v* tag lineage
  # (app-v0.2.0, ...), and whichever lineage is closer in history wins. When
  # an app-v* tag was the most recent, installs recorded provenance like
  # "app-v0.2.0-26-g95d01ca" instead of "v1.1.8-27-g95d01ca" -- a string the
  # app's own version comparison (agmsg_core_version_status in agmsg.rs)
  # can't parse as semver, which it then treats as "outdated" unconditionally.
  top="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  # THE TWO SIDES ARE IN DIFFERENT PATH SPACES ON WINDOWS, so the equality was
  # always false there and every Git Bash install recorded the VERSION file
  # instead of the describe string (#830):
  #
  #   $SCRIPT_DIR            /tmp/tmp.XXXX/agmsg        MSYS form, from bash
  #   git --show-toplevel    C:/Users/.../tmp.XXXX/agmsg  native form, from git
  #
  # `cygpath -m` is the mixed form git reports — the same second chance this
  # file already takes for the writable paths below, and the same one
  # `agmsg_cmdline_names_path` takes in compat.sh, where the identical mismatch
  # made four watcher-ownership checks answer "not ours" on Windows.
  #
  # The condition below is a CAPABILITY, not an operating system: where cygpath
  # is not on PATH, `native` stays empty and this is the plain comparison and
  # nothing else. Saying "off Windows" instead would be wider than the code —
  # this file's own test drives the second branch on macOS and Linux by putting
  # a cygpath stub on PATH.
  #
  # Where cygpath is absent, fails, returns nothing, or returns a path unequal
  # to git's toplevel, the recorded value is the fallback, exactly as before.
  # A wrong answer that happened to equal the toplevel would still take the
  # describe branch, so this is a set of conditions and not a guarantee that
  # the worst case is the old behaviour.
  native=""
  if command -v cygpath >/dev/null 2>&1; then
    native="$(cygpath -m "$SCRIPT_DIR" 2>/dev/null || true)"
  fi
  if [ -n "$top" ] && { [ "$top" = "$SCRIPT_DIR" ] || { [ -n "$native" ] && [ "$top" = "$native" ]; }; } \
      && v="$(git -C "$SCRIPT_DIR" describe --tags --always --dirty --abbrev=7 --match 'v[0-9]*' 2>/dev/null)" \
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

# Types the installer renders their OWN shared SKILL.md for (their template.md
# differs from codex's). Everything else -- codex itself, plus claude-code and
# copilot, which keep separate dedicated copies elsewhere -- gets the codex-
# typed shared SKILL.md. One list, read by three call sites below (fresh
# install's template pick, --update's template pick, and --update's type
# re-detection from the SKILL.md already on disk): before #846, the third site
# hardcoded its own, narrower copy of this same set (missing opencode/hermes/
# cursor) that had already drifted from the other two -- re-detecting one of
# those three types as "codex" and then, via the template pick, overwriting
# the SKILL.md the installer itself had written with the wrong flavor.
AGMSG_SHARED_SKILL_TPL_TYPES="gemini antigravity opencode hermes cursor grok-build pi"

# Put <src> at <dest>, then remove any leftover <src>. The arm is chosen by
# <dest>, so the fix's scope matches the defect's (#747):
#   - regular <dest>: `mv` — an atomic rename, so an interrupted install leaves
#     either the whole old config or the whole new one, never a torn file. This
#     is the common path and must stay atomic.
#   - symlinked <dest>: write THROUGH the link (a redirect follows it) so a
#     config.toml managed as a symlink (stow/chezmoi/manual dotfiles) keeps its
#     link and its target receives the edit. `mv` would replace the link with a
#     plain file and strand the edit on a detached copy — the actual #747 bug.
#     This arm is non-atomic (there is no atomic write-through-a-link with plain
#     POSIX tools), but the exposure is confined to symlink users, whose target
#     is typically a version-controlled dotfile.
move_into_place() {
  if [ -L "$2" ]; then
    cat "$1" > "$2" && rm -f "$1"
  else
    mv "$1" "$2"
  fi
}

configure_codex_sandbox() {
  # --- Configure Codex sandbox (if Codex is installed) ---
  # The Codex bridge writes pidfiles/sockets/request files under the
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
    ' "$code_config" > "$code_config.tmp" && move_into_place "$code_config.tmp" "$code_config"
  elif grep -q '^\[sandbox_workspace_write\]' "$code_config" 2>/dev/null; then
    # Section exists but no writable_roots
    awk -v entries="$entries" '
      { print }
      /^\[sandbox_workspace_write\]/ { print "writable_roots = [" entries "]" }
    ' "$code_config" > "$code_config.tmp" && move_into_place "$code_config.tmp" "$code_config"
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
      echo "  --agent-type <t>  Agent type: claude-code, codex, gemini, antigravity, opencode, hermes, cursor, grok-build, pi"
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
  # Captured before CMD_NAME gets defaulted/resolved below, so it still means
  # "the caller typed --cmd" specifically (#553's shim-force decision needs
  # exactly that, not "we ended up with some skill name one way or another").
  CMD_WAS_EXPLICIT=false
  [ -n "$CMD_NAME" ] && CMD_WAS_EXPLICIT=true
  # Find existing install. If --cmd was passed, update exactly that skill.
  # Otherwise, scan for installs and require exactly one: a glob expands in
  # collation order, not installation order, and nothing records which
  # install came first, so guessing from a list of more than one is a
  # silent coin flip on which install (and the shared ~/.agents/bin/codex
  # shim it refreshes) gets updated (#599). A single install is unaffected
  # -- this is the common case and it still "just works".
  #
  # No name-based exclusion for backup-shaped directories: --cmd has no
  # reserved-name validation, so any pattern that would catch a real backup
  # (e.g. "agmsg.bak-20260731") can equally match a legitimately chosen
  # install name (e.g. "agmsg.bak-tool") -- there is no substring that is
  # guaranteed to mean "not a real install" (co2 review, #659). A leftover
  # backup directory that still carries the .agmsg marker is therefore just
  # another candidate: it makes the set ambiguous, and ambiguous is exactly
  # what this fix already refuses to guess through, below.
  if [ -n "$CMD_NAME" ]; then
    SKILL_DIR="$AGENTS_DIR/skills/$CMD_NAME"
    if [ ! -f "$SKILL_DIR/.agmsg" ]; then
      echo "  ! Not installed: ~/.agents/skills/$CMD_NAME. Run ./install.sh --cmd $CMD_NAME first." >&2
      exit 1
    fi
  else
    candidates=()
    for d in "$AGENTS_DIR"/skills/*/; do
      d="${d%/}"
      [ -f "$d/.agmsg" ] && candidates+=("$d")
    done
    case "${#candidates[@]}" in
      0) SKILL_DIR="" ;;
      1) SKILL_DIR="${candidates[0]}" ;;
      *)
        echo "  ! Several agmsg installs found:" >&2
        for d in "${candidates[@]}"; do
          echo "      $(basename "$d")" >&2
        done
        echo "  ! --update with no --cmd cannot tell which one you mean. Pass --cmd <name> to pick one." >&2
        exit 1
        ;;
    esac
  fi
  if [ -z "$SKILL_DIR" ]; then
    echo "  ! Not installed. Run ./install.sh first." >&2
    exit 1
  fi
  SKILL_NAME="$(basename "$SKILL_DIR")"
  CMD_NAME="$SKILL_NAME"
  echo "  Updating $SKILL_NAME..."
  if [ -z "$AGENT_TYPE" ]; then
    # Re-detect the type this install's shared SKILL.md was last rendered for,
    # from the whoami.sh line its own template prints (#846) -- every
    # renderable type's line is unambiguous against every other's; see the
    # cross-grep this list is built from, noted alongside
    # AGMSG_SHARED_SKILL_TPL_TYPES above. codex is not grepped for: it is the
    # default a match against this list falls back to.
    AGENT_TYPE="codex"
    for _agmsg_t in $AGMSG_SHARED_SKILL_TPL_TYPES; do
      if grep -q "whoami.sh.*$_agmsg_t" "$SKILL_DIR/SKILL.md" 2>/dev/null; then
        AGENT_TYPE="$_agmsg_t"
        break
      fi
    done
    unset _agmsg_t
  fi
  # The shared SKILL.md uses the codex template by default; the types in
  # AGMSG_SHARED_SKILL_TPL_TYPES get their own. (claude-code and copilot reuse
  # the codex-typed shared SKILL.md; their dedicated copies are dropped
  # separately below.)
  TPL_TYPE="codex"
  case " $AGMSG_SHARED_SKILL_TPL_TYPES " in
    *" $AGENT_TYPE "*) TPL_TYPE="$AGENT_TYPE" ;;
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
  # Refresh / install the Pi skill. Pi auto-discovers ~/.pi/agent/skills and
  # ~/.agents/skills; the shared SKILL.md is Codex-typed, so keep a Pi-typed
  # copy in Pi's own skills dir (later locations win on name collision).
  PI_SKILL_DIR="$HOME/.pi/agent/skills/$SKILL_NAME"
  if [ -d "$HOME/.pi" ]; then
    mkdir -p "$PI_SKILL_DIR"
    sed "s/__SKILL_NAME__/$SKILL_NAME/g" "$(agmsg_type_template_path pi)" > "$PI_SKILL_DIR/SKILL.md"
  fi
  cp "$SCRIPT_DIR/openai.yaml" "$SKILL_DIR/agents/openai.yaml" 2>/dev/null || true
  # A team config written by an older release can be group- or world-writable,
  # and the sync engine refuses to read one that is (#804). Upgrading does not
  # rewrite files that already exist, so without this the release we are asking
  # people to install is the release that stops them: joined on v1.2.0-rc.5,
  # upgraded as told, and now the binding they already had is rejected.
  #
  # This is a HISTORICAL correction, not a sweep of every authority file. The
  # set an older release's write path could have left wrong is exactly
  # `teams/<team>/config.json`, because it is the only one written by shell
  # under the caller's umask; `<storage>/remote-sync/<team>.json` and the
  # retained age checkpoint are written by Node with an explicit 0600 on a
  # fresh `wx` file, and that code is byte-identical at v1.2.0-rc.5. Those two
  # are still authority files the engine refuses on mode -- a mode changed by
  # hand is outside this walk, and the pasteable remedy in the refusal is what
  # covers that case.
  #
  # Within what it does walk, the selection is meant to be exactly the files
  # the engine refuses ON MODE, so this cannot correct a file into a state the
  # engine still refuses, and cannot touch one it would have accepted:
  #
  #   -type f      a symlink is refused by the engine BEFORE mode is consulted
  #                ("must not be a symbolic link"), so chmod-ing one would
  #                change a file OUTSIDE the store and announce a repair that
  #                repaired nothing. `[ -f ]` follows symlinks; this does not.
  #   -perm -g+w   two tests, not one `-go+w`: `-perm -MODE` means ALL of the
  #   -perm -o+w   named bits, so the combined form skips a file writable by
  #                only one of them.
  #   find, glob   `teams/*/config.json` silently drops a team whose name
  #                begins with a dot, and lib/validate.sh allows those -- it
  #                rejects `.` and `..` but not `.anything`. find descends
  #                regardless of the leading character.
  #   one traversal, not two `find` starts per binding.
  #
  # `go-w` rather than a numeric mode: the owner's bits and any read access the
  # operator deliberately granted are theirs, not ours to normalise.
  #
  # Skipped on Windows, where the engine skips the mode check itself
  # (`process.platform !== "win32"` guards it, and it is the LAST thing it
  # consults). MSYS reports modes the filesystem does not really carry, so
  # without this the walk would announce that the sync engine refuses a file the
  # sync engine is perfectly happy with -- on every update, on the one platform
  # where the sentence cannot be true.
  #
  # Said out loud, per file. A permission change the operator cannot see is
  # indistinguishable from one that did not happen, and this one runs without
  # being asked for.
  if ! is_windows_host; then
    # Same scheme as lib/shquote.sh, inline rather than sourced: the installer
    # must not depend on the tree it is in the middle of writing. A team name
    # may contain a space or a single quote -- lib/validate.sh rejects only
    # empty / `.` / `..` / `/` / `\` / a leading `-` / control characters -- so
    # a path printed for someone to paste has to survive both.
    agmsg_shq() {
      printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
    }
    # -print0 and `read -d ''` because the path is arbitrary UTF-8. A newline
    # cannot appear in a team name (validate.sh rejects control characters), but
    # nothing here needs to rely on that.
    find "$SKILL_DIR/teams" -mindepth 2 -maxdepth 2 -name config.json -type f \
      \( -perm -g+w -o -perm -o+w \) -print0 2>/dev/null |
      while IFS= read -r -d '' agmsg_binding; do
        if chmod go-w "$agmsg_binding" 2>/dev/null; then
          echo "  + tightened $agmsg_binding (an older release left it group- or world-writable; the sync engine refuses those)"
        else
          printf '  ! could not tighten %s -- run: chmod go-w %s\n' \
            "$agmsg_binding" "$(agmsg_shq "$agmsg_binding")" >&2
        fi
      done || true
    unset -f agmsg_shq
  fi
  chmod +x "$SKILL_DIR/scripts/"*.sh
  chmod +x "$SKILL_DIR/scripts/drivers/types/codex/"*.sh 2>/dev/null || true
  # Refresh the Codex monitor shim (~/.agents/bin/codex) if it's ours. --update
  # cp's the new codex-shim-install.sh but does not re-run it, so a shim from an
  # older install keeps its stale baked exec path after the
  # types/ -> scripts/drivers/types/ move. Re-running install regenerates it with
  # the new path; install is idempotent and overwrites only an agmsg shim (a
  # user's own codex binary fails is_agmsg_shim and is left untouched).
  #
  # Forced ONLY when the caller typed --cmd (CMD_WAS_EXPLICIT, captured above
  # before CMD_NAME could be defaulted/resolved to anything else): that is
  # the documented recovery path for #553 (a different install's --cmd having
  # clobbered the shim), and naming the target explicitly is what makes
  # reclaiming it safe. Bare `--update` (no --cmd) resolves SKILL_DIR by
  # scanning for an existing install WITHOUT failing closed on more than one
  # candidate on this base (#599; the fail-closed fix is PR #659, not yet
  # merged here) -- so on a multi-install machine, bare `--update` today can
  # land on an install the caller never named at all. Forcing unconditionally
  # would let THAT arbitrarily-selected install steal the shim from another
  # one, compounding #599 with a #553-shaped consequence (review finding).
  # Not forcing means bare `--update` still refreshes a shim this SAME
  # install already owns (the common single-install case, unaffected either
  # way) but no longer silently reaches past a shim someone else owns.
  #
  # Capture status into a variable rather than piping it straight into
  # `grep -q` (measured, not theoretical): status now prints a second "owner:"
  # line (#553), and `grep -q` exits the instant it matches the first line,
  # closing its end of the pipe. status's own `echo` of the second line then
  # hits a reader that is already gone -- SIGPIPE, a nonzero exit for that
  # stage -- and under this script's `pipefail`, that alone flips the whole
  # `if` to false even though grep DID match. A one-line status (as this had
  # before #553) never triggers it: there is no second write for the closed
  # pipe to reject. Capturing first reads status to completion regardless of
  # how many lines it prints, so growing its output again later can't reopen
  # this.
  CODEX_SHIM="$SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh"
  CODEX_SHIM_STATUS=""
  [ -x "$CODEX_SHIM" ] && CODEX_SHIM_STATUS="$(AGMSG_CODEX_SHIM_INSTALL_QUIET=1 "$CODEX_SHIM" status 2>/dev/null || true)"
  if printf '%s' "$CODEX_SHIM_STATUS" | grep -q '^installed:'; then
    CODEX_SHIM_FORCE=""
    [ "$CMD_WAS_EXPLICIT" = true ] && CODEX_SHIM_FORCE=1
    if AGMSG_CODEX_SHIM_INSTALL_QUIET=1 AGMSG_CODEX_SHIM_FORCE="$CODEX_SHIM_FORCE" "$CODEX_SHIM" install >/dev/null; then
      echo "  + refreshed Codex monitor shim (~/.agents/bin/codex)"
    fi
  fi
  install_windows_helpers
  INSTALLED_VERSION="$(agmsg_source_version)"
  printf '%s\n' "$INSTALLED_VERSION" > "$SKILL_DIR/VERSION"
  echo "  + updated scripts, templates, and SKILL.md (version $INSTALLED_VERSION)"
  echo "  ~ DB and team configs preserved"
  configure_codex_sandbox
  echo ""
  echo "  ! Restart any running agent sessions to pick up the updated scripts."
  echo "    In-flight watch.sh processes detect this and stand down on their own;"
  echo "    reopening the session brings delivery back."
  echo ""
  echo "  ! A running sync engine stands down when it can tell it was updated, and"
  echo "    does not come back. When it cannot tell, it keeps running the engine"
  echo "    code it loaded before the update."
  echo "    Check each team you sync remotely:"
  echo ""
  echo "      remote.sh status <team>"
  echo ""
  echo "    There is no supported way to replace a running engine yet, and"
  echo "    'engine stale' is not proof that one has stopped (#963, #954)."
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
# codex template by default; the types in AGMSG_SHARED_SKILL_TPL_TYPES get their own.
TPL_TYPE="codex"
case " $AGMSG_SHARED_SKILL_TPL_TYPES " in
  *" $AGENT_TYPE "*) TPL_TYPE="$AGENT_TYPE" ;;
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
# older layout (no-op when no agmsg shim is present). See the --update block
# above. NOT forced (#553): unlike --update, a fresh install here gives no
# signal that the caller means to take over an EXISTING install's shim, so a
# --cmd for a second/different name must not silently repoint it away from
# whichever install already owns it. codex-shim-install.sh itself refuses that
# and says whose it is; surface that here instead of swallowing it.
CODEX_SHIM="$SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh"
CODEX_SHIM_STATUS=""
[ -x "$CODEX_SHIM" ] && CODEX_SHIM_STATUS="$(AGMSG_CODEX_SHIM_INSTALL_QUIET=1 "$CODEX_SHIM" status 2>/dev/null || true)"
if printf '%s' "$CODEX_SHIM_STATUS" | grep -q '^installed:'; then
  # Stdout suppressed (mirrors the --update block's success case above);
  # stderr is NOT, since codex-shim-install.sh's own refusal already names the
  # current owner and the exact consequence of forcing -- repeating a
  # shorter, separate version of that here would risk saying something
  # different from what actually happens.
  if AGMSG_CODEX_SHIM_INSTALL_QUIET=1 "$CODEX_SHIM" install >/dev/null; then
    echo "  + refreshed Codex monitor shim (~/.agents/bin/codex)"
  fi
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

# Nothing moves stores here. Installing must not change where a team's messages
# live: programs outside agmsg read the shared store directly, and an install
# that relocated their data would break them without anything saying so. A team
# moves to its own store only when connecting requires it, and only that team —
# see scripts/drivers/partition/ and internal/migrate-team-store.sh.

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

# --- Install Pi skill ---
# Pi auto-discovers ~/.pi/agent/skills/<name>/SKILL.md (and ~/.agents/skills as
# a fallback). The shared ~/.agents/skills/<name>/SKILL.md is Codex-typed and
# would mis-identify a Pi session — keep the Pi copy separate. Delivery writes
# a project-local extension at <project>/.pi/extensions/agmsg.ts.
PI_SKILL_DIR="$HOME/.pi/agent/skills/$CMD_NAME"
if [ -d "$HOME/.pi" ]; then
  mkdir -p "$PI_SKILL_DIR"
  sed "s/__SKILL_NAME__/$CMD_NAME/g" "$(agmsg_type_template_path pi)" > "$PI_SKILL_DIR/SKILL.md"
  echo "  + installed /$CMD_NAME skill to ~/.pi/agent/skills/"
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
echo "    1. Restart your agent (Claude Code / Codex / Gemini CLI / Antigravity / OpenCode / Pi) to pick up the new skill"
echo "    2. Run the command to join a team:"
echo "       Claude Code:  /$CMD_NAME"
echo "       Codex:        \$$CMD_NAME"
echo "       Gemini CLI:   \$$CMD_NAME"
echo "       Antigravity:  \$$CMD_NAME"
echo "       Copilot CLI:  /$CMD_NAME"
echo "       OpenCode:     \$$CMD_NAME"
echo "       Pi:           /$CMD_NAME"
echo "       It will prompt for team name and agent name on first run."
echo ""
echo "  Docs: https://agmsg.cc/"
echo ""
