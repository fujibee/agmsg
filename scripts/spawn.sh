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
#   spawn.sh <agent-type> <name> --boot-prompt "<initial task>" [options]
#
#   <agent-type>   any registered type whose manifest is spawnable: a `cli=`
#                  binary (direct-CLI launch) or a `spawn=` node launcher
#   <name>         actas identity for the spawned agent
#
# Options:
#   --boot-prompt <text>    an initial task for the spawned agent. When given, the
#                      boot prompt becomes the actas slash command followed
#                      (newline-separated) by <text>, so the new agent claims
#                      its identity AND acts on the task in its first turn —
#                      handy for a codex peer (no Monitor), where a message
#                      sent after spawn would never reach the idle session.
#                      An empty string (`--boot-prompt ""`) means no task.
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
#                      `spawn.terminal`. This is the OS-terminal COMMAND axis.
#   --terminal-driver <name>
#                      force WHICH terminal axis places the member: tmux | herdr |
#                      plain. A different axis from --terminal above: this selects
#                      the driver, that is the OS-terminal command template. Bypasses
#                      detection (otherwise $TMUX -> tmux -> herdr -> OS terminal).
#                      Overrides $AGMSG_TERMINAL_DRIVER (the CLI flag wins).
#   --no-wait          don't block on the readiness handshake; return as soon
#                      as the agent is launched (fire-and-forget)
#   --ready-timeout N  seconds to wait for readiness before giving up
#                      (default 90; on timeout, prints status=timeout, exit 3)
#   --model <id>       launch the agent on a specific model. The id is passed
#                      through to the CLI unchecked (the CLI rejects unknown
#                      ids); the flag spelling comes from the type's manifest
#                      `model_arg=`. Refused for a type with no model_arg.
#   --fresh            force a brand-new session even when the role has a
#                      resumable prior session. Without it, a type that supports
#                      resume (manifest `resume_arg=`) is brought back into its
#                      last session's context when that transcript still exists
#                      (#339); with it, spawn always boots fresh.
#
# Spawn options: extra CLI args to always pass a given type's launched
# binary (e.g. a default permission mode or sandbox policy), configured
# per-type in a YAML file rather than hardcoded — see
# scripts/lib/spawn-options.sh. File: $AGMSG_SPAWN_OPTIONS_FILE, else
# ~/.agmsg/config/spawn_options.yaml. Optional; a missing file/section is a
# no-op.
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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/spawn-options.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/role-session.sh"  # role->session record lookup (#339)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/boot-command.sh"  # shared boot-command construction (#339)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/terminal-registry.sh"  # terminals axis: placement via drivers

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
PROMPT=""            # --boot-prompt: optional initial task appended to the actas prompt
                     # (empty string = no task, so the `[ -n "$PROMPT" ]` guard
                     #  below leaves the boot prompt unchanged)
TEAM=""
TMUX_TARGET="pane"   # pane | window
SPLIT="h"            # h | v
TERMINAL_TMPL=""     # --terminal override (resolved below if empty)
# --terminal-driver / AGMSG_TERMINAL_DRIVER: a NEW surface that forces WHICH terminal
# axis places the member (tmux | herdr | plain), bypassing detection. Distinct from
# --terminal / AGMSG_TERMINAL, which is the OS-terminal command TEMPLATE (unchanged).
TERMINAL_DRIVER="${AGMSG_TERMINAL_DRIVER:-}"
WAIT_READY=1         # block until the spawned agent's watcher attaches
READY_TIMEOUT=90     # seconds to wait for readiness before giving up
MODEL_ID=""          # --model: pass-through model id for the launched CLI
FRESH=0              # --fresh: force a fresh session even if the role is resumable

while [ $# -gt 0 ]; do
  case "$1" in
    # `${2?...}` (not `:?`) errors only when the arg is MISSING; an explicit
    # empty string (`--boot-prompt ""`) is allowed through and treated as "no task"
    # by the `[ -n "$PROMPT" ]` guard, so a scripted `--boot-prompt "$VAR"` with an
    # empty VAR degrades to a plain spawn instead of aborting.
    --boot-prompt)  PROMPT="${2?--boot-prompt needs a task}"; shift 2 ;;
    --project) PROJECT="${2:?--project needs a path}"; shift 2 ;;
    --team)    TEAM="${2:?--team needs a name}"; shift 2 ;;
    --window)  TMUX_TARGET="window"; shift ;;
    --split)   SPLIT="${2:?--split needs h|v}"; shift 2 ;;
    --terminal) TERMINAL_TMPL="${2:?--terminal needs a template}"; shift 2 ;;
    --terminal-driver) TERMINAL_DRIVER="${2:?--terminal-driver needs a name (tmux|herdr|plain)}"; shift 2 ;;
    --no-wait) WAIT_READY=0; shift ;;
    --ready-timeout) READY_TIMEOUT="${2:?--ready-timeout needs seconds}"; shift 2 ;;
    --model) MODEL_ID="${2:?--model needs a model id}"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$SPLIT" in h|v) ;; *) die "--split must be 'h' or 'v'" ;; esac
case "$READY_TIMEOUT" in ''|*[!0-9]*) die "--ready-timeout must be a whole number of seconds" ;; esac

# Validate the terminal-driver override HERE, before any state change (co1): it is a
# deterministic argument typo, so it must fail like --split does — before the role is
# registered and a boot file is written (place_and_launch runs after both), and
# before an unrelated "no team" error can mask it. The accepted set is EXACTLY the
# public contract place_and_launch dispatches (tmux|herdr|plain), derived from the
# same list — an external spawn-capable driver would pass a capability check here but
# have no dispatch arm, so it must be rejected at parse time, not after the pre-join.
# Generalizing to arbitrary spawn-capable drivers is the launcher→driver reroute's
# scope. place_and_launch keeps its own guard as defence in depth.
case "$TERMINAL_DRIVER" in
  ''|tmux|herdr|plain) ;;
  *) die "unknown terminal driver '$TERMINAL_DRIVER' (--terminal-driver / AGMSG_TERMINAL_DRIVER); expected tmux, herdr or plain" ;;
esac

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
PROJECT="$(agmsg_normalize_project_path "$PROJECT")"

# --- Resolve the launch method from the manifest ---
# A non-empty `spawn=` launcher means this type runs via a Node launcher (e.g. an
# external add-on); otherwise it is a direct-CLI launch. The `cli=` binary is
# REQUIRED for direct-CLI types and OPTIONAL for node launchers (which resolve
# their own runtime). No per-type case — all data-driven from the manifest.
#
# `cli=` is trusted manifest data (agmsg ships it, not runtime user input), so
# it may be a single binary name OR a fixed command-line prefix of several
# space-separated tokens — a subcommand and/or fixed flags a CLI needs before
# its own options (e.g. `opencode run --interactive`, whose message is not a
# top-level argument). Only the first word names the actual executable to
# resolve/check; the rest are passed through as-is in the boot script below.
SPAWN_LAUNCHER="$(agmsg_type_get "$AGENT_TYPE" spawn)"
CLI_BIN="$(agmsg_type_get "$AGENT_TYPE" cli)"
CLI_BIN_EXE="${CLI_BIN%% *}"
CLI_PATH=""
if [ -n "$CLI_BIN" ]; then
  command -v "$CLI_BIN_EXE" >/dev/null 2>&1 \
    || die "'$CLI_BIN_EXE' not found on PATH — install the ${AGENT_TYPE} CLI first"
  CLI_PATH="$(command -v "$CLI_BIN_EXE")"
elif [ -z "$SPAWN_LAUNCHER" ]; then
  die "agent type '$AGENT_TYPE' manifest declares neither a 'cli' binary nor a 'spawn' launcher"
fi

# --model is pass-through: the model id is handed to the CLI unchecked (the CLI
# rejects an unknown id), so agmsg never has to track each vendor's model list.
# The flag SPELLING differs per CLI, so it comes from the manifest `model_arg=`
# (e.g. claude-code/grok-build use --model, codex uses -m). A type with no
# model_arg has no known flag, so --model is refused rather than guessed.
MODEL_ARG="$(agmsg_type_get "$AGENT_TYPE" model_arg)"
if [ -n "$MODEL_ID" ] && [ -z "$MODEL_ARG" ]; then
  die "agent type '$AGENT_TYPE' does not support --model (no model_arg in its manifest)"
fi

# Note: prompt_arg= (some CLIs require the actas prompt as a named flag's value
# rather than a bare positional, e.g. antigravity's --prompt-interactive) is
# resolved inside agmsg_role_cli_args (lib/boot-command.sh) now, so it stays in
# sync with the name/resume flags across spawn and resurrect-panes.sh.

# Session display name (#339). A type whose manifest declares `name_arg=` (e.g.
# claude-code's -n) is launched with `<name_arg> <team>-<agent>`, so the spawned
# session is born named after its role: meaningful in the prompt box / resume
# picker, and -- key for the tmux-resurrect hook -- recorded verbatim in the
# argv resurrect saves. Types without the key skip naming (unchanged). The name
# joins team and agent with a '-'; either half may itself contain '-', so the
# role-session record stores the whole `name=` for reverse lookup rather than
# splitting it apart.
# SESSION_NAME (<team>-<agent>) and the resume-or-fresh decision (#339) are both
# computed AFTER team resolution below (a project-resolved --team is only known
# then). The role-identity CLI args (name_arg/resume_arg/prompt) are emitted by
# agmsg_role_cli_args (lib/boot-command.sh), so the launch flag order stays in
# sync with resurrect-panes.sh.

# Session-identity env vars to strip from a spawned same-type child (issue #294).
# A terminal launcher (tmux new-window/split-window, a new OS terminal) copies
# the parent shell's exported environment verbatim. When the spawner is itself a
# session of the SAME CLI type (e.g. a claude-code session running
# `agmsg spawn claude-code <name>`), the child inherits the parent's
# session-identity vars (claude-code's CLAUDE_CODE_SESSION_ID) and mistakes the
# parent's session for its own — every turn then fails with an Authentication
# error despite valid credentials. Unset them in the generated boot script so the
# child starts with a clean identity.
#
# This reads a dedicated `spawn_unset_env=` manifest key, NOT `detect=`. `detect=`
# names the vars whoami uses to recognize a live session of a type, but those are
# not always session-identity vars: gemini's `detect=GEMINI_API_KEY ...` is a
# CREDENTIAL, and unsetting it would break the spawned child's auth — the opposite
# of the fix. `spawn_unset_env=` lists only vars that are safe (and necessary) to
# drop on spawn; unset (the default) strips nothing.
SPAWN_UNSET_VARS="$(agmsg_type_get "$AGENT_TYPE" spawn_unset_env)"

# Extra CLI args for this type from the spawn options file (opt-in, see
# scripts/lib/spawn-options.sh). Read line-by-line — never word-split — so a
# value containing spaces stays a single token.
SPAWN_OPT_TOKENS=()
while IFS= read -r _spawn_opt_tok; do
  SPAWN_OPT_TOKENS+=("$_spawn_opt_tok")
done < <(agmsg_spawn_options_tokens "$AGENT_TYPE")

# Resolve the node launcher path from the manifest (not hardcoded), if any.
SPAWN_AGENT=""
if [ -n "$SPAWN_LAUNCHER" ]; then
  NODE_BIN="${AGMSG_NODE_BIN:-$(command -v node 2>/dev/null || true)}"
  [ -n "$NODE_BIN" ] || die "'node' not found on PATH — spawning '$AGENT_TYPE' requires Node.js"
  type_dir="$(agmsg_type_dir "$AGENT_TYPE")" \
    || die "agent type '$AGENT_TYPE' is not registered (no scripts/drivers/types/$AGENT_TYPE/type.conf)"
  SPAWN_AGENT="$type_dir/$SPAWN_LAUNCHER"
  [ -f "$SPAWN_AGENT" ] || die "spawn launcher not found for '$AGENT_TYPE': $SPAWN_AGENT"
fi

# --- Resolve the team to join <name> into ---
# When --team is omitted, derive it from any team that already has an agent
# registered for this project (any type). Zero or many → require --team.
resolve_team() {
  [ -d "$TEAMS_DIR" ] || return 0
  local config_file team_name cfg_sql project_sql_in count_for_project
  local found=""
  # Read each config via readfile() and compare with SQL string literals rather
  # than `.param set` bindings: the sqlite3 shell's dot-command tokenizer does
  # NOT honour SQL '' escaping, so a value containing a single quote (a project
  # path like /tmp/pro'j) breaks `.param set`. SQL string literals do honour ''.
  project_sql_in=$(agmsg_project_sql_in_list "$PROJECT")
  for config_file in "$TEAMS_DIR"/*/config.json; do
    [ -f "$config_file" ] || continue
    # readfile() needs a native-Windows path — agmsg_sql_readfile_path converts and SQL-escapes it.
    cfg_sql=$(agmsg_sql_readfile_path "$config_file")
    team_name=$(agmsg_sqlite_mem \
      "SELECT json_extract(CAST(readfile('$cfg_sql') AS TEXT), '\$.name');")
    # Does any agent in this team have a registration for PROJECT (any type)?
    count_for_project=$(agmsg_sqlite_mem "
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
      WHERE json_extract(r.value, '\$.project') IN ($project_sql_in);
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

# Role's session display name (#339): now that TEAM is final, join it to the
# agent name. Emitted into the boot script when the type declares name_arg.
SESSION_NAME="${TEAM}-${NAME}"

# Resume-or-fresh decision (#339): resumable session id, or empty for a fresh
# boot. All fail-open gates (force --fresh, no resume_arg, no record, stale/
# missing transcript) live in agmsg_role_resume_uuid (lib/boot-command.sh), so
# spawn and resurrect-panes.sh decide identically.
RESUME_UUID="$(agmsg_role_resume_uuid "$AGENT_TYPE" "$TEAM" "$NAME" "$PROJECT" "$FRESH")"

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
#
# When --boot-prompt is given, append the task newline-separated so the agent claims
# its identity AND acts on the task in the same first turn. This is the only way
# to hand a one-shot goal to a codex peer, which has no Monitor and so never
# notices a message sent after it goes idle (see docs/codex-monitor-beta.md).
# Base actas prompt: `<cmd_prefix><cmd_name> actas <name>` (the cmd_prefix "/"
# vs "$" per-CLI subtlety and the custom-install command name live in
# agmsg_actas_prompt, lib/boot-command.sh, shared with resurrect-panes.sh). When
# --boot-prompt gives a task, append it newline-separated so the agent claims its
# identity AND acts on the task in the same first turn -- the only way to hand a
# one-shot goal to a codex peer, which has no Monitor.
ACTAS_PROMPT="$(agmsg_actas_prompt "$AGENT_TYPE" "$NAME")"
if [ -n "$PROMPT" ]; then
  ACTAS_PROMPT="${ACTAS_PROMPT}
${PROMPT}"
fi

# Git Bash / MSYS path conversion rewrites exec args that look like absolute
# POSIX paths when invoking a native Windows binary: a '/<cmd> actas <name>'
# initial prompt reaches the CLI as 'C:/Program Files/Git/<cmd> actas <name>'
# and the agent never sees a valid skill invocation. Exclude args starting
# with the slash command from conversion. The exclusion is prefix-scoped on
# purpose — MSYS_NO_PATHCONV=1 would also stop converting genuine POSIX-path
# args (e.g. a node launcher's --project /e/...) that native CLIs rely on.
# Only the '/' prefix is path-shaped; '$'-prefixed prompts (#283) are never
# converted, and the variable is inert outside MSYS environments.
# cmd_prefix/cmd_name are resolved exactly as agmsg_actas_prompt does
# (lib/boot-command.sh) -- #344 moved that resolution into the helper, so the two
# inputs the guard needs are recomputed here rather than read from now-absent vars.
_msys_cmd_name="$(basename "$SKILL_DIR")"
_msys_cmd_prefix="$(agmsg_type_get "$AGENT_TYPE" cmd_prefix)"
[ -n "$_msys_cmd_prefix" ] || _msys_cmd_prefix="/"
MSYS_GUARD=""
if [ "$_msys_cmd_prefix" = "/" ]; then
  MSYS_GUARD="MSYS2_ARG_CONV_EXCL=/${_msys_cmd_name} "
fi

BOOT_DIR="${TMPDIR:-/tmp}/agmsg-spawn"
mkdir -p "$BOOT_DIR" 2>/dev/null || true
# Best-effort GC of boot scripts left behind by spawns whose window was closed
# before the script could remove itself (see the trailing rm below).
# GC matches both the bare and the .command-suffixed form (see the rename below).
find "$BOOT_DIR" -name 'boot-*' -type f -mtime +1 -delete 2>/dev/null || true
BOOT="$(mktemp "$BOOT_DIR/boot-XXXXXX")"
# macOS `open -a Terminal` (launch_macos_terminal) only runs a file as a shell
# script if it ends in .command, so rename there. Every other launcher invokes
# the script through bash (Linux/Windows Terminal) or runs it via its shebang
# (tmux) — and on Windows the .command extension makes Explorer/psmux open it in
# Notepad instead of executing it (#282), so keep the bare executable path.
case "$(uname -s)" in
  Darwin) mv "$BOOT" "$BOOT.command"; BOOT="$BOOT.command" ;;
esac
{
  echo '#!/usr/bin/env bash'
  printf 'cd %q || exit 1\n' "$PROJECT"
  # Mark the launched session as spawn-born (#339): the CLI inherits this, so the
  # actas flow knows the session is already named <team>-<agent> (name_arg) and
  # suppresses the "rename this session" tip meant for hand-started sessions.
  echo 'export AGMSG_SPAWNED=1'
  # Drop inherited same-type session-identity vars before exec'ing the CLI (#294).
  if [ -n "$SPAWN_UNSET_VARS" ]; then
    printf 'unset %s\n' "$SPAWN_UNSET_VARS"
  fi
  if [ -n "$SPAWN_AGENT" ]; then
    # Node-launcher path: pass the universal agmsg context + the actas prompt.
    # Type-specific config is the launcher's own default/env, so core stays
    # generic and names no add-on. Spawn-options tokens (if any) land before
    # --initial-input, same relative position as the direct-CLI path below.
    printf '%s%q %q \\\n' "$MSYS_GUARD" "$NODE_BIN" "$SPAWN_AGENT"
    printf '  --name %q \\\n' "$NAME"
    printf '  --team %q \\\n' "$TEAM"
    printf '  --project %q \\\n' "$PROJECT"
    for _tok in ${SPAWN_OPT_TOKENS[@]+"${SPAWN_OPT_TOKENS[@]}"}; do
      printf '  %q \\\n' "$_tok"
    done
    printf '  --initial-input %q\n' "$ACTAS_PROMPT"
  else
    # Direct-CLI launch:
    # `<cli> [<resume_arg> <uuid>] [<model_arg> <model_id>] [spawn-options...] [<name_arg> <name>] [<prompt_arg>] "/<cmd> actas <name>"`.
    # cli is emitted unquoted — it is trusted fixed-prefix manifest data (see
    # above) that may itself be several tokens (e.g. `opencode run --interactive`).
    # The resume head (#339) is emitted RIGHT AFTER the cli, before all other
    # args: mandatory for a subcommand-shaped resume (codex `resume <id>`),
    # harmless for a flag-shaped one (claude `--resume <id>`) -- see
    # agmsg_role_resume_head. model_arg is the manifest flag spelling (bare, not
    # %q-quoted); the model id and every spawn-options token are quoted. The
    # role-identity tail (name/prompt_arg + the actas prompt) is emitted by
    # agmsg_role_cli_args so its flag order matches resurrect-panes.sh.
    # MSYS_GUARD (#336) prefixes the CLI line as a command-local env assignment;
    # emitted with %s (not %q) so it stays an assignment, not a single token.
    printf '%s%s' "$MSYS_GUARD" "$CLI_BIN"
    agmsg_role_resume_head "$AGENT_TYPE" "$RESUME_UUID"
    [ -n "$MODEL_ID" ] && printf ' %s %q' "$MODEL_ARG" "$MODEL_ID"
    for _tok in ${SPAWN_OPT_TOKENS[@]+"${SPAWN_OPT_TOKENS[@]}"}; do
      printf ' %q' "$_tok"
    done
    # Role-identity tail: name the session and pass the actas prompt. The actas
    # prompt runs in BOTH fresh and resume cases -- resume restores context only,
    # so the actas re-run re-establishes the watcher, the lock, and the active
    # FROM (claim is idempotent per sid).
    agmsg_role_cli_args "$AGENT_TYPE" "$SESSION_NAME" "$ACTAS_PROMPT"
    printf '\n'
  fi
  echo 'rm -f "$0" 2>/dev/null'   # self-clean once the agent exits
  echo 'exec "${SHELL:-/bin/bash}" -i'
} > "$BOOT"
chmod +x "$BOOT"

# ============================================================================
# Placement — every launcher just runs $BOOT.
# ============================================================================

# Write the placement record, and REPORT if the write itself failed. The record is
# the ONLY authority peek / poke / despawn --force have over a spawned member, so a
# live pane with no record (disk full, permission) is a distinct, worse state than a
# clean spawn — not a success (co1/tl, full-head review). We cannot un-spawn the pane
# that already exists, so we do not roll back; we set a flag the main flow turns into
# `status=spawned-but-unrecorded` (a DIFFERENT word from `spawned`) with the pane id,
# and a non-zero exit, so the operator knows a window exists it cannot address.
SPAWN_UNRECORDED=0
SPAWN_UNREC_REF=""
# requirement 1 (herdr): set when the pane's pre-input readiness could NOT be verified
# before the boot was typed (herdr process-info did not answer). A WARNING, distinct
# from the post-input startup verdict — see the note where it is emitted.
SPAWN_READINESS_UNVERIFIED=0
_record_placement() {   # <terminal> <id>
  local rec ref
  rec="$(agmsg_spawn_path "$TEAM" "$NAME")"
  ref="$(agmsg_terminal_ref "$1" "$2")"
  mkdir -p "$(dirname "$rec")" 2>/dev/null || true
  # Atomic (temp + rename via agmsg_write_atomic, available transitively through
  # terminal-registry.sh): a failed write must NOT truncate an existing correct
  # record — SPAWN_UNRECORDED is reported only AFTER the old record is proven
  # intact, not on top of one this write just emptied. The helper adds the
  # trailing newline, so the row is passed without one.
  if ! agmsg_write_atomic "$rec" "$(printf '%s\t%s\t%s' "$ref" "$PROJECT" "$AGENT_TYPE")" 2>/dev/null; then
    SPAWN_UNRECORDED=1
    SPAWN_UNREC_REF="$ref"
    return 1
  fi
  return 0
}

launch_in_tmux() {
  # $TMUX is set (we are inside a tmux pane), but the `tmux` client binary
  # still has to be on PATH for split-window/new-window to work. In a
  # PATH-starved environment (e.g. spawned indirectly from cron/CI into a
  # tmux pane) it may be missing. Fail fast with a clear message rather than
  # aborting on a raw "tmux: command not found", and don't silently fall back
  # to an OS terminal — opening a separate window while inside tmux is more
  # confusing than an explicit error.
  # $TMUX is set but the `tmux` client still has to be on PATH. Keep this spawn-level
  # pre-check with its clear message (and its "do not fall back to an OS terminal"
  # intent) rather than letting the driver abort on a raw "tmux: command not found".
  command -v tmux >/dev/null 2>&1 \
    || die "\$TMUX is set but the tmux binary is not on PATH; add it to PATH, or run outside tmux to use the OS-terminal path"

  # On Windows (psmux), tmux launches processes via Windows APIs that do not process
  # shebang lines; an extensionless boot script is accepted but never executed
  # (#335). Wrap with `bash -l` — same pattern as launch_windows_terminal.
  local -a tmux_boot=("$BOOT")
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) tmux_boot=(bash -l "$BOOT") ;;
  esac

  # Place THROUGH the tmux driver (the terminals axis). target fully specifies the
  # placement: a window, or a horizontal/vertical split. The driver names the
  # window/pane after the agent and turns automatic-rename off.
  local target
  if [ "$TMUX_TARGET" = "window" ]; then target=window
  elif [ "$SPLIT" = "v" ];        then target=pane-v
  else                                 target=pane-h
  fi
  agmsg_terminal_load tmux || die "could not load the tmux terminal driver"
  local target_id
  target_id="$(terminal_spawn "$NAME" "$PROJECT" "$target" "${tmux_boot[@]}")" \
    || die "tmux placement failed"

  # Record placement as <terminal>:<id> so despawn --force (and peek/poke) read the
  # terminal from the record; despawn still tolerates the pre-axis bare %N/@N. See #109.
  _record_placement tmux "$target_id" || true
}

# The OS-terminal launchers (macOS `open -g -a`, Linux emulators, Windows Terminal,
# and the `{cmd}` template) now live in the PLAIN terminal driver
# (drivers/terminals/plain/ops.sh); _launch_os_terminal below routes through it, so
# the plain driver is a real production caller and the OS-terminal path has one
# implementation, not two.

is_herdr_env() {
  [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ] \
    && command -v herdr >/dev/null 2>&1
}

launch_in_herdr() {
  # --window needs a workspace. Keep spawn's fallback UX (warn + split) rather than
  # the driver's hard "window target needs HERDR_WORKSPACE_ID" error: downgrade the
  # target BEFORE calling the driver.
  if [ "$TMUX_TARGET" = "window" ] && [ -z "${HERDR_WORKSPACE_ID:-}" ]; then
    echo "spawn: --window requested but \$HERDR_WORKSPACE_ID is not set; falling back to split" >&2
    TMUX_TARGET="pane"
  fi
  local target
  if [ "$TMUX_TARGET" = "window" ]; then target=window
  elif [ "$SPLIT" = "v" ];        then target=pane-v
  else                                 target=pane-h
  fi
  # Place THROUGH the herdr driver: it splits/creates, extracts the new pane id (with
  # the pane-id grammar guard, so a malformed/partial response fails closed), renames
  # and runs the boot, and prints the new pane id.
  agmsg_terminal_load herdr || die "could not load the herdr terminal driver"
  # terminal_spawn carries requirement 1's THREE outcomes in its exit code: 0 typed and
  # the pre-input state verified ready; 4 typed but that state UNVERIFIED; 3 NOT typed
  # because the pane never reached its prompt. Capture the code and branch — a bare
  # `|| die` would turn arm 4 (a success with a caveat) into a spurious failure.
  local new_id rc=0
  new_id="$(terminal_spawn "$NAME" "$PROJECT" "$target" "$BOOT")" || rc=$?
  case "$rc" in
    0) : ;;
    4) SPAWN_READINESS_UNVERIFIED=1 ;;
    3) die "herdr pane was not ready for input, so '${NAME}' was not launched (see the reason above)" ;;
    *) die "herdr placement failed (split/tab create returned no usable pane id)" ;;
  esac
  # Record placement as <terminal>:<id>. despawn reads the terminal from the record
  # (herdr pane ids contain ':', preserved by the first-colon ref split).
  _record_placement herdr "$new_id" || true
}

_launch_os_terminal() {
  # Place THROUGH the plain terminal driver (tl 2026-09-02: the driver claims
  # capabilities=spawn despawn, so production must actually go through it, not a
  # duplicate). plain's terminal_spawn does the OS-terminal launch — a {cmd} template
  # on any OS, else the current macOS terminal (`open -g -a`) / a Linux emulator /
  # Windows Terminal, with the same headless + platform guards it moved from here —
  # and returns '-' (no addressable pane, so no placement record for plain). It reads
  # AGMSG_TERMINAL as the template / macOS app hint; hand it the resolved value.
  agmsg_terminal_load plain || die "could not load the plain terminal driver"
  # CAPTURE the driver's record-op stdout — it is a protocol value ('-' = placed, no
  # addressable pane), not something a spawn user should see on stdout. Verify it is
  # exactly '-' (a malformed/empty result is NOT a success), and do not echo it.
  local _plain_id
  _plain_id="$(AGMSG_TERMINAL="$TERMINAL_TMPL" terminal_spawn "$NAME" "$PROJECT" - "$BOOT")" \
    || die "could not open an OS terminal (see the reason above); run inside tmux/herdr or set a {cmd} AGMSG_TERMINAL"
  [ "$_plain_id" = '-' ] \
    || die "the plain terminal driver returned an unexpected placement id ('${_plain_id}') — expected '-' (an OS terminal has no addressable pane)"
  # "launched", NOT "spawned" (tl): every placement line below states only that the
  # pane was created and the boot typed into it — a PLACEMENT fact. It is deliberately
  # not the word "spawned", because whether the agent actually STARTED is answered
  # later and separately by the status= line (status=ready = a positive observation
  # that its watcher attached; status=launched-unconfirmed = a type with no handshake,
  # so startup cannot be confirmed here). tl hit "spawned" printed while the agent had
  # not started (a shell prompt ate the first keystroke of the boot command).
  # The message keeps the two shapes the tests and users know: a custom template vs a
  # plain new window.
  if [ -n "$TERMINAL_TMPL" ] && is_terminal_template "$TERMINAL_TMPL"; then
    echo "launched ${AGENT_TYPE} '${NAME}' via custom terminal template"
  else
    echo "launched ${AGENT_TYPE} '${NAME}' in a new terminal window"
  fi
}

place_and_launch() {
  # --terminal-driver / AGMSG_TERMINAL_DRIVER forces WHICH axis places the member,
  # bypassing detection. It is a spawn/name PREFERENCE on a NEW surface (tl
  # 2026-08-31); tmux/herdr each still require their own environment (a forced tmux
  # split needs to be inside tmux, a forced herdr split needs HERDR_PANE_ID), so an
  # impossible force fails in the launcher with that launcher's own error.
  if [ -n "$TERMINAL_DRIVER" ]; then
    agmsg_terminal_dir "$TERMINAL_DRIVER" >/dev/null 2>&1 \
      || die "unknown terminal driver '$TERMINAL_DRIVER' (--terminal-driver / AGMSG_TERMINAL_DRIVER); expected tmux, herdr or plain"
    case "$TERMINAL_DRIVER" in
      tmux)  launch_in_tmux;      echo "launched ${AGENT_TYPE} '${NAME}' in tmux (${TMUX_TARGET})" ;;
      herdr) launch_in_herdr;     echo "launched ${AGENT_TYPE} '${NAME}' in herdr (${TMUX_TARGET})" ;;
      plain) _launch_os_terminal ;;
      *)     die "terminal driver '$TERMINAL_DRIVER' cannot place a spawn (no spawn capability)" ;;
    esac
    return 0
  fi

  # No override: PRESERVE the detection order — $TMUX (tmux-inside-herdr backward
  # compat) → herdr → OS terminal. tl deferred the nested spawn-placement decision to
  # the live matrix, so this does NOT switch to the registry's herdr-first resolver.
  if [ -n "${TMUX:-}" ]; then
    launch_in_tmux
    echo "launched ${AGENT_TYPE} '${NAME}' in tmux (${TMUX_TARGET})"
    return 0
  fi

  if is_herdr_env; then
    launch_in_herdr
    echo "launched ${AGENT_TYPE} '${NAME}' in herdr (${TMUX_TARGET})"
    return 0
  fi

  _launch_os_terminal
}

# Readiness handshake (#108). The spawned agent's actas flow starts its watcher
# in exclusive mode, which touches a ready sentinel once it's actually
# receiving. Block until that appears so the leader doesn't send a job into the
# cold-start window (before the watcher attaches) and lose it.
#
# Types with `monitor=no` do not produce a spawn-awaitable readiness sentinel, so
# skip the wait. That covers types with no Monitor at all (codex) AND types whose
# watcher attaches via the agent's own launch rather than a spawn-time sentinel
# (grok-build, whose monitor mode is real but not awaitable here) — receive there
# is poll-based or agent-launched anyway.
READY_PATH="$(agmsg_ready_path "$TEAM" "$NAME")"
SKIPPED_READINESS_BY_TYPE=0
if [ "$(agmsg_type_get "$AGENT_TYPE" monitor)" = "no" ] && [ "$WAIT_READY" = "1" ]; then
  WAIT_READY=0
  SKIPPED_READINESS_BY_TYPE=1
  echo "spawn: '$AGENT_TYPE' has no spawn readiness handshake — skipping readiness wait (--no-wait implied)" >&2
fi

# Clear any stale sentinel before launching so we only observe THIS spawn's
# watcher attaching.
[ "$WAIT_READY" = "1" ] && rm -f "$READY_PATH" 2>/dev/null || true

place_and_launch

# requirement 1 arm 3 (herdr): the boot was typed, but the pane's pre-input readiness
# could not be verified. Say so with the BEFORE-typing reason — deliberately worded
# apart from the AFTER-typing "launched-unconfirmed" below, so an operator can tell
# which check was blind (utildev). Per co1's priority this is only a WARNING: the final
# startup verdict is still the post-input one — a watcher that then attaches makes the
# status ready, and a monitor=no type still reports launched-unconfirmed on its own.
if [ "$SPAWN_READINESS_UNVERIFIED" = "1" ]; then
  echo "spawn: could not verify '${NAME}'s pane was at its shell prompt BEFORE the boot was typed (herdr process-info did not answer). If the agent does not appear, a startup shell prompt may have eaten the first keystroke — read the pane. This is the before-typing check; the startup confirmation below is separate." >&2
fi

# The pane was placed. If its placement record could not be written, the member is
# running but unaddressable by peek/poke/despawn --force — report that distinctly and
# fail, rather than let a normal `status=ready` imply everything is fine (co1/tl).
if [ "$SPAWN_UNRECORDED" = "1" ]; then
  echo "status=spawned-but-unrecorded name=${NAME} team=${TEAM} ref=${SPAWN_UNREC_REF}"
  echo "spawn: '${NAME}' launched, but its placement record could not be written (disk full or a permission error) — peek/poke/despawn --force cannot reach it. The pane is ${SPAWN_UNREC_REF}; close it manually if needed." >&2
  exit 1
fi

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
elif [ "$SKIPPED_READINESS_BY_TYPE" = "1" ]; then
  # monitor=no: there is no readiness handshake, so spawn CANNOT confirm the agent
  # actually started — only that its boot was placed/typed. Do not let the
  # "spawned in <terminal>" placement log stand as success: a boot that never ran
  # (measured — a shell that prompts at startup eats the FIRST keystroke of the boot
  # command, so `/var/…/boot` becomes `var/…/boot: no such file or directory`) would
  # otherwise read as a clean spawn. Report startup as UNCONFIRMED, distinctly (tl).
  echo "status=launched-unconfirmed name=${NAME} team=${TEAM} note=no-readiness-handshake"
  echo "spawn: '${NAME}' was launched, but this type has no readiness handshake so its STARTUP IS UNCONFIRMED. If it does not appear, read its pane — a shell that prompts at startup (e.g. an update prompt) can eat the first keystroke of the boot command, and the failure then looks like a slow start." >&2
else
  # Explicit --no-wait (WAIT_READY cleared by the flag, not by a monitor=no type): the
  # caller opted OUT of the readiness handshake, so — exactly like monitor=no — startup
  # is not confirmed here, only that the boot was placed/typed. co1: both no-confirmation
  # paths report launched-unconfirmed, so this arm must exist too; a distinct note keeps
  # the two reasons legible. Silence (a bare `launched …` at rc 0) would imply success.
  echo "status=launched-unconfirmed name=${NAME} team=${TEAM} note=no-wait"
  echo "spawn: '${NAME}' was launched with --no-wait, so its STARTUP IS UNCONFIRMED (the readiness handshake was skipped by request). If it does not appear, read its pane." >&2
fi
