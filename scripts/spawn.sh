#!/usr/bin/env bash
set -euo pipefail

# spawn.sh — launch a NEW agent process and have it take an actas identity.
#
# Given an agent-type and an actas <name>, spawn.sh:
#   1. pre-joins <name> to a team for the target project (so the child's
#      actas flow just claims the role instead of prompting for a team),
#   2. opens a place to run it — a tmux pane/window when run inside tmux,
#      otherwise an OS terminal window,
#   3. launches the agent CLI there with `/agmsg actas <name>` as its
#      initial prompt, so the new agent comes up already registered and
#      addressable.
#
# Usage:
#   spawn.sh <agent-type> <name> [options]
#
#   <agent-type>   any registered type whose manifest is spawnable: a `cli=`
#                  binary (direct-CLI launch) or a `spawn=` node launcher
#   <name>         actas identity for the spawned agent
#
# Options:
#   --project <path>   project to launch in (default: $PWD)
#   --team <team>      team to join <name> into (default: auto-resolved from
#                      the project's existing registrations; required when the
#                      project belongs to more than one team)
#   --window           open a new tmux WINDOW instead of splitting the pane
#                      (only meaningful inside tmux)
#   --split h|v        tmux split direction when splitting the current window
#                      (h = left/right [default], v = top/bottom)
#   --terminal <tmpl>  terminal command template for the non-tmux path; a
#                      `{cmd}` placeholder is replaced with the path to the
#                      generated boot script (an executable file the terminal
#                      should run). Overrides $AGMSG_TERMINAL and config
#                      `spawn.terminal`.
#   --no-wait          don't block on the readiness handshake; return as soon
#                      as the agent is launched (fire-and-forget)
#   --ready-timeout N  seconds to wait for readiness before giving up
#                      (default 90; on timeout, prints status=timeout, exit 3)
#
# Readiness: by default spawn blocks until the new agent's watcher attaches and
# is receiving (it prints `status=ready ...`), so a leader can safely send work
# right after spawn returns without racing the agent's cold start. Codex has no
# Monitor, so the wait is skipped for codex.
#
# Scope note: spawnable types are those whose manifest declares `spawnable=yes`;
# macOS is the primary target, Linux and
# Windows are best-effort (no guarantee — please open an issue/PR if a given
# terminal does not work). Headless environments (no tmux and no usable
# terminal) error out, because the agent CLIs need an interactive terminal.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
TEAMS_DIR="$SKILL_DIR/teams"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"

die() { echo "spawn: $*" >&2; exit 1; }

# --- Parse positional args ---
AGENT_TYPE="${1:-}"
NAME="${2:-}"
[ -n "$AGENT_TYPE" ] || die "Usage: spawn.sh <agent-type> <name> [options]"
[ -n "$NAME" ] || die "Usage: spawn.sh <agent-type> <name> [options]"
shift 2 || true

# A type is spawnable iff its manifest declares `spawnable=yes` (direct-CLI) OR a
# `spawn=` node launcher. The error lists the computed spawnable set from the
# registry — no type name is hardcoded here.
spawnable_types() {
  local t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    # `if` (not `&& printf`) so a non-spawnable last type does not leave the loop
    # — and thus the function — with a non-zero status, which `set -e`+pipefail
    # would turn into a silent exit at the `SUPPORTED_LIST=$(...)` assignment.
    if [ "$(agmsg_type_get "$t" spawnable)" = "yes" ] || [ -n "$(agmsg_type_get "$t" spawn)" ]; then
      printf '%s\n' "$t"
    fi
  done <<EOF
$(agmsg_known_types | sort -u)
EOF
  return 0
}
SUPPORTED_LIST="$(spawnable_types | paste -sd, - | sed 's/,/, /g')"
if ! agmsg_is_known_type "$AGENT_TYPE"; then
  die "unknown agent type '$AGENT_TYPE' (supported: ${SUPPORTED_LIST})"
elif [ "$(agmsg_type_get "$AGENT_TYPE" spawnable)" != "yes" ] && [ -z "$(agmsg_type_get "$AGENT_TYPE" spawn)" ]; then
  # Gate must match spawnable_types(): spawnable iff `spawnable=yes` OR a `spawn=`
  # node launcher. (Honouring only spawnable=yes here would reject a node-launcher
  # add-on while still listing it in SUPPORTED_LIST.)
  die "agent type '$AGENT_TYPE' is not supported by spawn yet (supported: ${SUPPORTED_LIST})"
fi

# --- Parse options ---
PROJECT="$PWD"
TEAM=""
TMUX_TARGET="pane"   # pane | window
SPLIT="h"            # h | v
TERMINAL_TMPL=""     # --terminal override (resolved below if empty)
WAIT_READY=1         # block until the spawned agent's watcher attaches
READY_TIMEOUT=90     # seconds to wait for readiness before giving up

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project needs a path}"; shift 2 ;;
    --team)    TEAM="${2:?--team needs a name}"; shift 2 ;;
    --window)  TMUX_TARGET="window"; shift ;;
    --split)   SPLIT="${2:?--split needs h|v}"; shift 2 ;;
    --terminal) TERMINAL_TMPL="${2:?--terminal needs a template}"; shift 2 ;;
    --no-wait) WAIT_READY=0; shift ;;
    --ready-timeout) READY_TIMEOUT="${2:?--ready-timeout needs seconds}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$SPLIT" in h|v) ;; *) die "--split must be 'h' or 'v'" ;; esac
case "$READY_TIMEOUT" in ''|*[!0-9]*) die "--ready-timeout must be a whole number of seconds" ;; esac

# Resolve the terminal override for the non-tmux path:
#   --terminal  >  $AGMSG_TERMINAL  >  config spawn.terminal
# A value containing a `{cmd}` placeholder is treated as a command template
# on every platform. A bare value (no placeholder) is honored only on macOS,
# as an app-name hint (e.g. "iterm"); on Linux/Windows a bare value is an
# error, since those paths need an explicit template to know how to invoke it.
if [ -z "$TERMINAL_TMPL" ]; then
  TERMINAL_TMPL="${AGMSG_TERMINAL:-}"
fi
if [ -z "$TERMINAL_TMPL" ]; then
  TERMINAL_TMPL="$("$SCRIPT_DIR/config.sh" get spawn.terminal "" 2>/dev/null || true)"
fi

is_terminal_template() { [[ "$1" == *"{cmd}"* ]]; }

# Normalize the project path so registrations/lookups are consistent with the
# rest of agmsg (which keys on the path as given by the caller's pwd).
if [ ! -d "$PROJECT" ]; then
  die "project path does not exist: $PROJECT"
fi
PROJECT="$(cd "$PROJECT" && pwd)"

# --- Resolve the launch method from the manifest ---
# A non-empty `spawn=` launcher means this type runs via a Node launcher (e.g. an
# external add-on); otherwise it is a direct-CLI launch. The `cli=` binary is
# REQUIRED for direct-CLI types and OPTIONAL for node launchers (which resolve
# their own runtime). No per-type case — all data-driven from the manifest.
SPAWN_LAUNCHER="$(agmsg_type_get "$AGENT_TYPE" spawn)"
CLI_BIN="$(agmsg_type_get "$AGENT_TYPE" cli)"
CLI_PATH=""
if [ -n "$CLI_BIN" ]; then
  command -v "$CLI_BIN" >/dev/null 2>&1 \
    || die "'$CLI_BIN' not found on PATH — install the ${AGENT_TYPE} CLI first"
  CLI_PATH="$(command -v "$CLI_BIN")"
elif [ -z "$SPAWN_LAUNCHER" ]; then
  die "agent type '$AGENT_TYPE' manifest declares neither a 'cli' binary nor a 'spawn' launcher"
fi
# Resolve the node launcher path from the manifest (not hardcoded), if any.
SPAWN_AGENT=""
if [ -n "$SPAWN_LAUNCHER" ]; then
  NODE_BIN="${AGMSG_NODE_BIN:-$(command -v node 2>/dev/null || true)}"
  [ -n "$NODE_BIN" ] || die "'node' not found on PATH — spawning '$AGENT_TYPE' requires Node.js"
  type_dir="$(agmsg_type_dir "$AGENT_TYPE")" \
    || die "agent type '$AGENT_TYPE' is not registered (no types/$AGENT_TYPE/type.conf)"
  SPAWN_AGENT="$type_dir/$SPAWN_LAUNCHER"
  [ -f "$SPAWN_AGENT" ] || die "spawn launcher not found for '$AGENT_TYPE': $SPAWN_AGENT"
fi

# --- Resolve the team to join <name> into ---
# When --team is omitted, derive it from any team that already has an agent
# registered for this project (any type). Zero or many → require --team.
resolve_team() {
  [ -d "$TEAMS_DIR" ] || return 0
  local config_file team_name cfg_sql proj_sql count_for_project
  local found=""
  # Read each config via readfile() and compare with SQL string literals rather
  # than `.param set` bindings: the sqlite3 shell's dot-command tokenizer does
  # NOT honour SQL '' escaping, so a value containing a single quote (a project
  # path like /tmp/pro'j) breaks `.param set`. SQL string literals do honour ''.
  proj_sql=$(printf '%s' "$PROJECT" | sed "s/'/''/g")
  for config_file in "$TEAMS_DIR"/*/config.json; do
    [ -f "$config_file" ] || continue
    cfg_sql=$(printf '%s' "$config_file" | sed "s/'/''/g")
    team_name=$(sqlite3 :memory: \
      "SELECT json_extract(CAST(readfile('$cfg_sql') AS TEXT), '\$.name');")
    # Does any agent in this team have a registration for PROJECT (any type)?
    count_for_project=$(sqlite3 :memory: "
      WITH cfg AS (SELECT CAST(readfile('$cfg_sql') AS TEXT) AS json),
      agents AS (
        SELECT
          CASE
            WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
            ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
          END AS registrations
        FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
      )
      SELECT COUNT(*)
      FROM agents, json_each(agents.registrations) AS r
      WHERE json_extract(r.value, '\$.project') = '$proj_sql';
    ")
    if [ "${count_for_project:-0}" -gt 0 ]; then
      found="${found:+$found
}$team_name"
    fi
  done
  printf '%s' "$found"
}

if [ -z "$TEAM" ]; then
  CANDIDATES="$(resolve_team)"
  CAND_COUNT=$(printf '%s' "$CANDIDATES" | grep -c . || true)
  if [ "$CAND_COUNT" -eq 1 ]; then
    TEAM="$CANDIDATES"
  elif [ "$CAND_COUNT" -eq 0 ]; then
    die "no team is registered for this project; pass --team <team>"
  else
    die "project belongs to multiple teams ($(printf '%s' "$CANDIDATES" | paste -sd, -)); pass --team <team>"
  fi
fi

# --- Pre-flight: refuse if <name> is currently held by another live session ---
# The child's actas flow would refuse anyway; failing here avoids launching a
# process that immediately can't take its identity.
STATE="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
case "$STATE" in
  other:*)
    die "actas '$NAME' in team '$TEAM' is held by a live session (${STATE#other:}); drop it there first" ;;
esac

# --- Pre-join so the child's actas just claims (no interactive team prompt) ---
# PROJECT here is the explicit spawn target (--project / $PWD), which may not be
# registered yet. Opt out of #92 pwd-resolution so join.sh registers exactly
# this path rather than rewriting it to the spawning session's own project.
AGMSG_RESOLVE_PROJECT=0 "$SCRIPT_DIR/join.sh" "$TEAM" "$NAME" "$AGENT_TYPE" "$PROJECT" >/dev/null

# --- Build the boot script the new agent will run ---
# Rather than embed a multiply-escaped command string into each platform's
# terminal invocation, write the launch steps into a temp executable script
# and have every launcher simply *run that file*. This keeps quoting sane
# across tmux, macOS, Linux emulators, Windows Terminal, and custom templates,
# and on macOS it lets us use `open -a` (a plain app launch) instead of
# `osascript ... do script`, which goes through AppleEvents and triggers the
# Automation (TCC) permission prompts users otherwise have to approve.
#
# The agent CLIs accept an initial prompt as a positional argument and submit
# it as the session's first message; passing the slash command makes the new
# agent run `/agmsg actas <name>` on boot. We cd into the project first so a
# cross-project spawn lands in the right tree, and drop into an interactive
# shell afterwards so the window/pane stays open with the agent's final output.
# The slash command is named after the installed command, which the user may
# have customized at install time (install.sh --cmd). Derive it from the skill
# dir basename so a custom install (e.g. `/m`) spawns `/m actas <name>` rather
# than a nonexistent `/agmsg actas <name>`.
CMD_NAME="$(basename "$SKILL_DIR")"
ACTAS_PROMPT="/${CMD_NAME} actas ${NAME}"

BOOT_DIR="${TMPDIR:-/tmp}/agmsg-spawn"
mkdir -p "$BOOT_DIR" 2>/dev/null || true
# Best-effort GC of boot scripts left behind by spawns whose window was closed
# before the script could remove itself (see the trailing rm below).
find "$BOOT_DIR" -name 'boot-*.command' -type f -mtime +1 -delete 2>/dev/null || true
BOOT="$(mktemp "$BOOT_DIR/boot-XXXXXX")"
mv "$BOOT" "$BOOT.command"   # .command so macOS `open` runs it in Terminal
BOOT="$BOOT.command"
{
  echo '#!/usr/bin/env bash'
  printf 'cd %q || exit 1\n' "$PROJECT"
  if [ -n "$SPAWN_AGENT" ]; then
    # Node-launcher path: pass the universal agmsg context + the actas prompt.
    # Type-specific config is the launcher's own default/env, so core stays
    # generic and names no add-on.
    printf '%q %q \\\n' "$NODE_BIN" "$SPAWN_AGENT"
    printf '  --name %q \\\n' "$NAME"
    printf '  --team %q \\\n' "$TEAM"
    printf '  --project %q \\\n' "$PROJECT"
    printf '  --initial-input %q\n' "$ACTAS_PROMPT"
  else
    printf '%q %q\n' "$CLI_BIN" "$ACTAS_PROMPT"
  fi
  echo 'rm -f "$0" 2>/dev/null'   # self-clean once the agent exits
  echo 'exec "${SHELL:-/bin/bash}" -i'
} > "$BOOT"
chmod +x "$BOOT"

# ============================================================================
# Placement — every launcher just runs $BOOT.
# ============================================================================

launch_in_tmux() {
  # $TMUX is set (we are inside a tmux pane), but the `tmux` client binary
  # still has to be on PATH for split-window/new-window to work. In a
  # PATH-starved environment (e.g. spawned indirectly from cron/CI into a
  # tmux pane) it may be missing. Fail fast with a clear message rather than
  # aborting on a raw "tmux: command not found", and don't silently fall back
  # to an OS terminal — opening a separate window while inside tmux is more
  # confusing than an explicit error.
  command -v tmux >/dev/null 2>&1 \
    || die "\$TMUX is set but the tmux binary is not on PATH; add it to PATH, or run outside tmux to use the OS-terminal path"

  # Name the window/pane after the agent rather than letting tmux fall back to
  # the boot script's filename (boot-XXXXXX). `automatic-rename off` keeps the
  # name from being clobbered once the boot script runs the CLI / drops to a
  # shell.
  local target_id
  if [ "$TMUX_TARGET" = "window" ]; then
    target_id="$(tmux new-window -P -F '#{window_id}' -n "$NAME" -c "$PROJECT" "$BOOT")"
    tmux set-window-option -t "$target_id" automatic-rename off 2>/dev/null || true
  else
    local dir="-h"; [ "$SPLIT" = "v" ] && dir="-v"
    target_id="$(tmux split-window "$dir" -P -F '#{pane_id}' -c "$PROJECT" "$BOOT")"
    tmux select-pane -t "$target_id" -T "$NAME" 2>/dev/null || true
  fi
  # Record placement so `despawn --force` can tear this member down even if its
  # watcher later can't respond to ctrl:despawn. tmux ids are self-describing:
  # %N = pane (kill-pane), @N = window (kill-window). See #109.
  printf '%s\t%s\t%s\n' "$target_id" "$PROJECT" "$AGENT_TYPE" \
    > "$(agmsg_spawn_path "$TEAM" "$NAME")" 2>/dev/null || true
}

launch_macos_terminal() {
  # `open -a` is a launch, not an AppleEvent, so it does not trip the
  # Automation (TCC) consent prompts that `osascript ... do script` does.
  local app="${1:-Terminal}"
  case "$app" in
    iterm|iterm2|iTerm|iTerm2) open -a iTerm "$BOOT" ;;
    *)                         open -a Terminal "$BOOT" ;;
  esac
}

launch_linux_terminal() {
  local term
  for term in x-terminal-emulator gnome-terminal konsole xfce4-terminal xterm; do
    command -v "$term" >/dev/null 2>&1 || continue
    case "$term" in
      gnome-terminal) gnome-terminal --working-directory="$PROJECT" -- "$BOOT" ;;
      konsole)        konsole --workdir "$PROJECT" -e "$BOOT" ;;
      *)              "$term" -e "$BOOT" ;;
    esac
    return 0
  done
  die "no supported terminal emulator found (tried gnome-terminal/konsole/xterm/...); set AGMSG_TERMINAL or run inside tmux"
}

launch_windows_terminal() {
  if command -v wt.exe >/dev/null 2>&1; then
    wt.exe new-tab bash -l "$BOOT"
    return 0
  fi
  if command -v wt >/dev/null 2>&1; then
    wt new-tab bash -l "$BOOT"
    return 0
  fi
  die "Windows Terminal (wt) not found; set AGMSG_TERMINAL or run inside tmux"
}

launch_with_template() {
  # User-supplied terminal command. `{cmd}` is replaced with the path to the
  # boot script (an executable file); if there is no placeholder, the path is
  # appended. Quote it so a TMPDIR with spaces still works.
  local q_boot; q_boot="$(printf '%q' "$BOOT")"
  local cmd
  if [[ "$TERMINAL_TMPL" == *"{cmd}"* ]]; then
    cmd="${TERMINAL_TMPL//\{cmd\}/$q_boot}"
  else
    cmd="$TERMINAL_TMPL $q_boot"
  fi
  bash -c "$cmd"
}

place_and_launch() {
  if [ -n "${TMUX:-}" ]; then
    launch_in_tmux
    echo "spawned ${AGENT_TYPE} '${NAME}' in tmux (${TMUX_TARGET})"
    return 0
  fi

  # Non-tmux: open an OS terminal. A {cmd} template wins outright on any OS.
  if [ -n "$TERMINAL_TMPL" ] && is_terminal_template "$TERMINAL_TMPL"; then
    launch_with_template
    echo "spawned ${AGENT_TYPE} '${NAME}' via custom terminal template"
    return 0
  fi

  case "$(uname -s)" in
    Darwin)
      # Default to the terminal the user is *currently* in, so spawning from
      # iTerm opens iTerm rather than jarringly launching Terminal.app. A bare
      # override (no {cmd}) is an explicit app-name hint and wins, e.g. "iterm".
      local mac_app="${TERMINAL_TMPL:-}"
      if [ -z "$mac_app" ]; then
        case "${TERM_PROGRAM:-}" in
          iTerm.app) mac_app="iterm" ;;
          *)         mac_app="Terminal" ;;
        esac
      fi
      launch_macos_terminal "$mac_app" ;;
    Linux)
      if [ -n "$TERMINAL_TMPL" ]; then
        die "AGMSG_TERMINAL/spawn.terminal must contain a {cmd} placeholder on Linux (got: $TERMINAL_TMPL)"
      fi
      # No display → cannot open a GUI terminal, and there is no tmux to fall
      # back to. The agent CLI needs an interactive terminal, so error.
      if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        die "headless environment: no tmux session and no display available — cannot open a terminal for ${CLI_BIN}. Run inside tmux, or set a {cmd} terminal template via AGMSG_TERMINAL."
      fi
      launch_linux_terminal ;;
    MINGW*|MSYS*|CYGWIN*)
      if [ -n "$TERMINAL_TMPL" ]; then
        die "AGMSG_TERMINAL/spawn.terminal must contain a {cmd} placeholder on Windows (got: $TERMINAL_TMPL)"
      fi
      launch_windows_terminal ;;
    *)
      die "unsupported platform '$(uname -s)' for the non-tmux path; run inside tmux or set a {cmd} terminal template via AGMSG_TERMINAL." ;;
  esac
  echo "spawned ${AGENT_TYPE} '${NAME}' in a new terminal window"
}

# Readiness handshake (#108). The spawned agent's actas flow starts its watcher
# in exclusive mode, which touches a ready sentinel once it's actually
# receiving. Block until that appears so the leader doesn't send a job into the
# cold-start window (before the watcher attaches) and lose it.
#
# Types without a Monitor (manifest `monitor=no`) never touch the readiness
# sentinel, so skip the wait for them (their receive is poll-based anyway).
READY_PATH="$(agmsg_ready_path "$TEAM" "$NAME")"
if [ "$(agmsg_type_get "$AGENT_TYPE" monitor)" = "no" ] && [ "$WAIT_READY" = "1" ]; then
  WAIT_READY=0
  echo "spawn: '$AGENT_TYPE' has no Monitor — skipping readiness wait (--no-wait implied)" >&2
fi

# Clear any stale sentinel before launching so we only observe THIS spawn's
# watcher attaching.
[ "$WAIT_READY" = "1" ] && rm -f "$READY_PATH" 2>/dev/null || true

place_and_launch

if [ "$WAIT_READY" = "1" ]; then
  waited=0
  while [ ! -e "$READY_PATH" ]; do
    if [ "$waited" -ge "$READY_TIMEOUT" ]; then
      echo "status=timeout name=${NAME} team=${TEAM} after=${READY_TIMEOUT}s"
      echo "spawn: '${NAME}' did not signal ready within ${READY_TIMEOUT}s — it may still be booting; re-spawn or raise --ready-timeout" >&2
      exit 3
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "status=ready name=${NAME} team=${TEAM} after=${waited}s"
fi
