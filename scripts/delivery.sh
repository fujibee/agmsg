#!/usr/bin/env bash
set -euo pipefail

# Manage how incoming messages reach this agent.
#
# Usage:
#   delivery.sh set <mode> <type> <project_path>
#   delivery.sh status [<type> <project_path>]
#   delivery.sh stop
#   delivery.sh restart [<project_path> <type>]
#
# Modes:
#   monitor  — SessionStart hook → Claude Code Monitor tool → watch.sh stream
#   turn     — Stop hook → check-inbox.sh between turns (legacy)
#   both     — monitor primary; turn as per-session safety net
#   off      — no automatic delivery
#
# settings.json injection is idempotent: each `set` call first strips any
# existing agmsg-owned SessionStart/Stop entries, then re-adds whichever
# the new mode requires. Re-running with the same mode is a no-op.
#
# For in-session activation, several actions print a final
# "AGMSG-DIRECTIVE:" line that a running Claude Code agent reads from the
# command output and acts on (invoke Monitor, TaskStop the watcher). This
# closes the gap where, without the directive, only the *next* session
# would pick up the mode change.

ACTION="${1:?Usage: delivery.sh set|status|restart ...}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_NAME="$(basename "$SKILL_DIR")"
RUN_DIR="$SKILL_DIR/run"
# instance-id derivation (#93) for the in-session monitor directive below.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/instance-id.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/node.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/type-registry.sh"
# storage.sh provides agmsg_sqlite_mem (CR-safe sqlite, #180); hooks-json.sh's
# primitives use it, so source storage first.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/storage.sh"
# JSON/SQLite hook-file primitives (sourced after SKILL_NAME is set above —
# strip/add reference it to detect agmsg-owned entries).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/hooks-json.sh"
# Shared "rule-file" delivery behavior (rulefile_apply), delegated to by the
# rule-file types' _delivery.sh plugs.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/delivery-rulefile.sh"

# The per-project delivery hooks file is the type's manifest `hooks_file=`
# (project-relative), not a hardcoded per-type case. The hook FORMAT written into
# it is still type-specific (apply_settings_* below).
resolve_hooks_file() {
  local type="$1"
  local project="$2"
  local rel
  rel="$(agmsg_type_get "$type" hooks_file)"
  if [ -z "$rel" ]; then
    echo "Unknown agent type: $type" >&2
    return 1
  fi
  # hooks_file is project-relative; reject absolute paths or traversal so a
  # manifest can't redirect writes outside the project.
  case "$rel" in
    /*|*..*) echo "Invalid hooks_file for $type: $rel" >&2; return 1 ;;
  esac
  echo "$project/$rel"
}

# Default delivery behavior: JSON event-hooks (SessionStart / SessionEnd / Stop)
# written into the type's hooks_file. Used by claude-code and codex. Rule-file
# types override this by defining agmsg_delivery_apply in scripts/drivers/types/<name>/_delivery.sh.
agmsg_delivery_apply_default() {
  local type="$1"
  local project="$2"
  local mode="$3"

  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")
  mkdir -p "$(dirname "$hooks_file")"

  # Whether hook entries also need a Windows-native "commandWindows" variant is
  # a per-type manifest fact (hook_windows_wrap=yes). Resolve it here — the layer
  # that knows agent types — and pass a plain flag down to add_event_entry_file,
  # which stays type-agnostic (see hooks-json.sh header).
  local ww
  ww=$(agmsg_type_get "$type" hook_windows_wrap 2>/dev/null || true)

  # Work on a temp copy so a partially-modified file never replaces the
  # original until the whole chain succeeds.
  local tmp_state
  tmp_state=$(mktemp "${TMPDIR:-/tmp}/agmsg-state.XXXXXX")
  if [ -f "$hooks_file" ]; then
    cp "$hooks_file" "$tmp_state"
  else
    printf '{}' > "$tmp_state"
  fi

  # 1) Strip any prior agmsg ownership from SessionStart, SessionEnd, Stop.
  strip_agmsg_event_file "$tmp_state" "SessionStart"
  strip_agmsg_event_file "$tmp_state" "SessionEnd"
  strip_agmsg_event_file "$tmp_state" "Stop"

  # 2) Re-add what this mode wants.
  case "$mode" in
    monitor)
      local ss="'$SKILL_DIR/scripts/session-start.sh' '$type' '$project'"
      local se="'$SKILL_DIR/scripts/session-end.sh'   '$type' '$project'"
      add_event_entry_file "$tmp_state" "SessionStart" "$ss" "$ww"
      add_event_entry_file "$tmp_state" "SessionEnd"   "$se" "$ww"
      ;;
    turn)
      local cmd="'$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'"
      add_event_entry_file "$tmp_state" "Stop" "$cmd" "$ww"
      ;;
    both)
      local ss="'$SKILL_DIR/scripts/session-start.sh' '$type' '$project'"
      local se="'$SKILL_DIR/scripts/session-end.sh'   '$type' '$project'"
      local st="'$SKILL_DIR/scripts/check-inbox.sh'   '$type' '$project'"
      add_event_entry_file "$tmp_state" "SessionStart" "$ss" "$ww"
      add_event_entry_file "$tmp_state" "SessionEnd"   "$se" "$ww"
      add_event_entry_file "$tmp_state" "Stop"         "$st" "$ww"
      ;;
    off)
      : # already stripped
      ;;
    *)
      rm -f "$tmp_state"
      echo "Unknown mode: $mode (use monitor|turn|both|off)" >&2
      return 1
      ;;
  esac

  prune_empty_hooks_file "$tmp_state"

  mv "$tmp_state" "$hooks_file"
}

# Default delivery entry points (Template Method). A type's plug
# (scripts/drivers/types/<name>/_delivery.sh) may override any subset of these:
#   agmsg_delivery_apply      — write the hook file for a mode (default: JSON event-hooks)
#   agmsg_delivery_on_enable  — side effects when enabling monitor/both (default: none)
#   agmsg_delivery_on_disable — side effects when turning delivery off  (default: none)
# A plug that wants the default apply can delegate to agmsg_delivery_apply_default.
agmsg_delivery_apply() { agmsg_delivery_apply_default "$@"; }
agmsg_delivery_on_enable() { :; }
# Default 'off' teardown: stop this project's watch.sh watchers. A type with its
# own runtime (e.g. codex's bridge) overrides this. Args: <type> <project>.
agmsg_delivery_on_disable() { kill_all_watchers "$2" >/dev/null 2>&1 || true; }

# Default delivery status (json-hooks types: claude-code, codex). Derives the mode
# from the settings hooks file's agmsg-owned SessionStart/Stop entries, then prints
# the per-event entry detail. Rule-file types override agmsg_delivery_status.
agmsg_delivery_status_default() {
  local type="$1" project="$2"
  local hf
  hf=$(resolve_hooks_file "$type" "$project")
  local has_ss=0 has_st=0
  if [ -f "$hf" ]; then
    local sql_hf
    sql_hf=$(sql_readfile_path "$hf")
    has_ss=$(agmsg_sqlite_mem "
      SELECT EXISTS(
        SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.SessionStart')) AS s,
          json_each(json_extract(s.value, '\$.hooks')) AS h
        WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
      );" 2>/dev/null || echo 0)
    has_st=$(agmsg_sqlite_mem "
      SELECT EXISTS(
        SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.Stop')) AS s,
          json_each(json_extract(s.value, '\$.hooks')) AS h
        WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
      );" 2>/dev/null || echo 0)
  fi
  local mode="off"
  if [ "$has_ss" = "1" ] && [ "$has_st" = "1" ]; then mode="both"
  elif [ "$has_ss" = "1" ]; then mode="monitor"
  elif [ "$has_st" = "1" ]; then mode="turn"
  fi
  echo "mode: $mode"

  if [ -f "$hf" ]; then
    local sql_hf count
    sql_hf=$(sql_readfile_path "$hf")
    # readfile() rather than interpolating the file contents into argv —
    # for large settings (#95) the latter hits MAX_ARG_STRLEN on Linux.
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.SessionStart'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "settings hooks file: $hf"
    echo "  SessionStart entries: $count"
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.SessionEnd'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "  SessionEnd entries:   $count"
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.Stop'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "  Stop entries:         $count"
  fi
}
agmsg_delivery_status() { agmsg_delivery_status_default "$@"; }

# Source the type's delivery plug (if present) so its overrides take effect.
# One type is handled per invocation, so the global overrides never go stale.
agmsg_delivery_load_plug() {
  local tdir
  tdir="$(agmsg_type_dir "$1" 2>/dev/null || true)"
  if [ -n "$tdir" ] && [ -f "$tdir/_delivery.sh" ]; then
    # shellcheck disable=SC1090
    . "$tdir/_delivery.sh"
  fi
}

apply_settings() {
  local type="$1" project="$2" mode="$3"
  agmsg_delivery_load_plug "$type"
  agmsg_delivery_apply "$type" "$project" "$mode"
}

CODEX_MONITOR_DOC_URL="https://github.com/fujibee/agmsg/blob/main/docs/codex-monitor-beta.md"

emit_monitor_directive() {
  local type="$1"
  local project="$2"
  local watch="$SKILL_DIR/scripts/watch.sh"

  # Claude Code exports CLAUDE_CODE_SESSION_ID for every subprocess of the
  # session. Bake it directly into the command so the agent never has to
  # invent a value — that lets SessionEnd find and clean the matching
  # pidfile reliably. Fall back to a generated id when the env var isn't
  # present (older CC, non-CC runtimes).
  local session_id="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -z "$session_id" ]; then
    if command -v uuidgen >/dev/null 2>&1; then
      session_id="agmsg-$(uuidgen | tr 'A-Z' 'a-z')"
    else
      session_id="agmsg-$(date +%s)-$$"
    fi
  fi

  # Key the watcher on the per-process instance id (#93) so parallel
  # --continue/--resume sessions sharing a session_id stay isolated. Baking the
  # composite into the directive matches SessionStart and makes the pidfile
  # liveness check below see the real watcher (idempotent in watch.sh).
  session_id="$(agmsg_normalize_instance_id "$session_id" "$type")"

  # Skip the directive when this CC session already has a live watcher —
  # invoking Monitor again would just spawn a duplicate and orphan the
  # previous watcher process.
  local pidfile="$RUN_DIR/watch.$session_id.pid"
  if [ -f "$pidfile" ]; then
    local existing
    existing=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
      cat <<EOF

A watch.sh is already streaming into this session (pid $existing). No
action needed — the existing watcher is the active one.
EOF
      return 0
    fi
  fi

  # Shell-quote each argv (printf %q) so a paste-and-run host shell keeps paths
  # with spaces or apostrophes intact; a plain '...' wrap breaks on /o'brien/...
  # (#188).
  local watch_command
  watch_command="$(printf '%q %q %q %q' "$watch" "$session_id" "$project" "$type")"
  cat <<EOF

AGMSG-DIRECTIVE: For this running session, invoke the Monitor tool now with:
  command: $watch_command
  description: agmsg inbox stream
  persistent: true

Pass the command above verbatim — the session_id is already filled in.
EOF
}

emit_stop_directive() {
  cat <<'EOF'

AGMSG-DIRECTIVE: If an agmsg watch Monitor task is running in this session,
find it with TaskList (description starts with "agmsg inbox stream") and
stop it with TaskStop. Existing watch.sh processes have already been killed
by this command.
EOF
}

# Stop the Codex monitor bridge(s) for a project and remove their run artifacts.
# Used by `set off codex` (and the manual counterpart to the not-yet-wired auto
# teardown, #149). Leaves the shared app-server and the global shim alone — only
# the per-identity bridge is project-scoped. Echoes how many were killed.
stop_codex_bridge() {
  local project="$1"
  local pairs team name pidfile bpid killed=0
  pairs=$("$SCRIPT_DIR/identities.sh" "$project" codex 2>/dev/null || true)
  if [ -n "$pairs" ]; then
    while IFS=$'\t' read -r team name _rest; do
      [ -n "$team" ] && [ -n "$name" ] || continue
      pidfile="$RUN_DIR/codex-bridge.$team.$name.pid"
      [ -f "$pidfile" ] || continue
      bpid=$(cat "$pidfile" 2>/dev/null || true)
      if [ -n "$bpid" ] && kill -0 "$bpid" 2>/dev/null; then
        kill "$bpid" 2>/dev/null && killed=$((killed + 1))
      fi
      rm -f "$pidfile" "${pidfile%.pid}.meta" "${pidfile%.pid}.log"
    done <<EOF
$pairs
EOF
  fi
  echo "$killed"
}

do_set() {
  local MODE="${1:?Usage: delivery.sh set <mode> <type> <project_path>}"
  local TYPE="${2:?Missing type}"
  local PROJECT="${3:?Missing project_path}"

  # Two-stage validation. First: is this even a real mode? The four mode names
  # are engine vocabulary (not type-specific), so a typo is caught here with a
  # generic message before any per-type logic.
  case "$MODE" in monitor|turn|both|off) ;; *)
    echo "Unknown mode: $MODE (use monitor|turn|both|off)" >&2; exit 1 ;;
  esac
  # Second: does THIS type accept the mode? A type declares the modes its CLI
  # accepts via the delivery_modes= manifest key (e.g. codex omits 'both' — the
  # bridge beta has no both-mode; rule-file types like opencode omit
  # 'monitor'/'both'). Reject anything not listed, before any file is touched.
  # Types without the key fall back to the full set so an unconfigured manifest
  # still works.
  local SUPPORTED_MODES
  SUPPORTED_MODES=$(agmsg_type_get "$TYPE" delivery_modes 2>/dev/null || true)
  [ -z "$SUPPORTED_MODES" ] && SUPPORTED_MODES="monitor turn both off"
  case " $SUPPORTED_MODES " in
    *" $MODE "*) ;;
    *)
      echo "Error: '$MODE' mode is not supported for $TYPE (supported: $SUPPORTED_MODES)." >&2
      exit 1 ;;
  esac

  apply_settings "$TYPE" "$PROJECT" "$MODE"

  echo "Delivery mode set to '$MODE' for $PROJECT ($TYPE)"

  case "$MODE" in
    monitor|both)
      # Type-specific enable side effects (shim install, watcher directive, …)
      # live in the type's plug as agmsg_delivery_on_enable; default is none.
      agmsg_delivery_on_enable "$MODE" "$TYPE" "$PROJECT"
      ;;
    turn)
      echo "Future sessions: Stop hook will check inbox between turns."
      # Stop only THIS project's watcher; other projects/sessions keep theirs.
      kill_all_watchers "$PROJECT" >/dev/null 2>&1 || true
      emit_stop_directive
      ;;
    off)
      echo "Future sessions: no automatic delivery."
      # Type-specific teardown via the plug (default: stop this project's
      # watchers; codex stops its bridge instead).
      agmsg_delivery_on_disable "$TYPE" "$PROJECT"
      # Only emit the in-session watcher-stop directive for types that actually
      # have an automatic delivery mode to stop. A manual-only type
      # (delivery_modes=off, e.g. hermes) has no Monitor/watcher, so the
      # directive would be noise — and a stray TaskStop could disturb an
      # unrelated agent's watcher. Data-driven, so no per-type branch here.
      case " $SUPPORTED_MODES " in
        *" monitor "*|*" turn "*|*" both "*) emit_stop_directive ;;
      esac
      ;;
  esac
}

do_status() {
  local TYPE="${1:-}"
  local PROJECT="${2:-}"

  # Mode is derived from the project's settings.local.json — there's no
  # global mode value. When called without <type> <project>, we can't infer
  # a project-scoped mode, so we just skip the mode line and report the
  # global watcher state below.
  # Mode + per-type status detail come from the type's delivery plug
  # (agmsg_delivery_status); default is JSON event-hooks, rule-file types override.
  if [ -n "$TYPE" ] && [ -n "$PROJECT" ]; then
    agmsg_delivery_load_plug "$TYPE"
    agmsg_delivery_status "$TYPE" "$PROJECT"
  fi

  if [ -d "$RUN_DIR" ]; then
    local alive=0 dead=0
    for f in "$RUN_DIR"/watch.*.pid; do
      [ -f "$f" ] || continue
      local pid
      pid=$(cat "$f" 2>/dev/null || echo "")
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        alive=$((alive + 1))
      else
        dead=$((dead + 1))
      fi
    done
    echo "watch processes: $alive alive, $dead stale pidfiles"
  fi
}

kill_all_watchers() {
  # With no argument, kills every running watch.sh (used by stop/restart).
  # With a <project> argument, kills only watchers launched for that project
  # path, so switching one project's delivery mode (set turn/off) never tears
  # down another project's — or another concurrent session's — monitor.
  local project="${1:-}"
  local killed=0
  if [ -d "$RUN_DIR" ]; then
    for f in "$RUN_DIR"/watch.*.pid; do
      [ -f "$f" ] || continue
      local pid cmd
      pid=$(cat "$f" 2>/dev/null || echo "")
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        # Defensive: only kill if the pid's command line still looks like
        # our watch.sh. Defends against pid recycling — a stale pidfile
        # could point at an unrelated process that reused the pid.
        cmd=$(ps -o args= -p "$pid" 2>/dev/null || true)
        case "$cmd" in
          *"$SKILL_DIR/scripts/watch.sh"*)
            # watch.sh argv is "watch.sh <session_id> <project> <type> [name]",
            # so the project path is a space-delimited field. When scoped,
            # skip (and preserve the pidfile of) watchers for other projects.
            if [ -n "$project" ]; then
              case " $cmd " in
                *" $project "*) ;;
                *) continue ;;
              esac
            fi
            kill "$pid" 2>/dev/null && killed=$((killed + 1)) ;;
          *) ;;  # not our watcher; leave it
        esac
      fi
      rm -f "$f"
    done
  fi
  echo "$killed"
}

do_stop() {
  local killed
  killed=$(kill_all_watchers)
  echo "Killed $killed watch process(es)."
  emit_stop_directive
}

do_restart() {
  local TYPE="${1:-}"
  local PROJECT="${2:-}"
  local killed
  killed=$(kill_all_watchers)
  echo "Killed $killed watch process(es)."
  if [ -n "$TYPE" ] && [ -n "$PROJECT" ]; then
    emit_stop_directive
    emit_monitor_directive "$TYPE" "$PROJECT"
  else
    emit_stop_directive
    cat <<'EOF'

To relaunch in this session, pass <type> <project_path> as arguments:
  delivery.sh restart claude-code /path/to/project
EOF
  fi
}

case "$ACTION" in
  set)     do_set "$@" ;;
  status)  do_status "$@" ;;
  stop)    do_stop "$@" ;;
  restart) do_restart "$@" ;;
  *)       echo "Unknown action: $ACTION (use set|status|stop|restart)" >&2; exit 1 ;;
esac
