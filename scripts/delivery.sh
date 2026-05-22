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

resolve_hooks_file() {
  local type="$1"
  local project="$2"
  case "$type" in
    claude-code) echo "$project/.claude/settings.local.json" ;;
    codex)       echo "$project/.codex/hooks.json" ;;
    *) echo "Unknown agent type: $type" >&2; return 1 ;;
  esac
}

read_settings_escaped() {
  if [ -f "$1" ]; then
    sed "s/'/''/g" "$1"
  else
    echo '{}'
  fi
}

# Strip any agmsg-owned hook entries from <event> in settings JSON. An entry
# is "agmsg-owned" when one of its inner hooks references a path under our
# skill directory. Result: the entire <event> array minus those entries
# (or .hooks.<event> deleted if the array becomes empty).
strip_agmsg_event() {
  local settings_esc="$1"
  local event="$2"

  sqlite3 :memory: "
    SELECT CASE
      WHEN json_extract('$settings_esc', '\$.hooks.$event') IS NULL THEN
        '$settings_esc'
      WHEN (SELECT count(*) FROM json_each(json_extract('$settings_esc', '\$.hooks.$event')) AS s
            WHERE NOT EXISTS (
              SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
              WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
            )) = 0 THEN
        json_remove('$settings_esc', '\$.hooks.$event')
      ELSE
        json_set('$settings_esc', '\$.hooks.$event',
          (SELECT json_group_array(json(s.value))
           FROM json_each(json_extract('$settings_esc', '\$.hooks.$event')) AS s
           WHERE NOT EXISTS (
             SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
             WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
           ))
        )
    END;
  "
}

# Append a single entry of the form {"matcher":"","hooks":[{"type":"command","command":"<cmd>"}]}
# to .hooks.<event>, creating arrays/objects as needed.
add_event_entry() {
  local settings_esc="$1"
  local event="$2"
  local cmd="$3"

  local entry="{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd\"}]}"
  local entry_esc
  entry_esc=$(printf '%s' "$entry" | sed "s/'/''/g")

  sqlite3 :memory: "
    WITH base AS (
      SELECT CASE WHEN json_extract('$settings_esc', '\$.hooks') IS NULL
                  THEN json_set('$settings_esc', '\$.hooks', json('{}'))
                  ELSE '$settings_esc' END AS s
    )
    SELECT CASE
      WHEN json_extract(s, '\$.hooks.$event') IS NULL THEN
        json_set(s, '\$.hooks.$event', json_array(json('$entry_esc')))
      ELSE
        json_set(s, '\$.hooks.$event',
          (SELECT json_group_array(json(v.value)) FROM (
             SELECT value FROM json_each(json_extract(s, '\$.hooks.$event'))
             UNION ALL
             SELECT '$entry_esc'
           ) v)
        )
    END
    FROM base;
  "
}

# Drop the entire .hooks object if it ended up empty after stripping.
prune_empty_hooks() {
  local s="$1"
  sqlite3 :memory: "
    SELECT CASE
      WHEN json_extract('$s', '\$.hooks') IS NULL THEN '$s'
      WHEN (SELECT count(*) FROM json_each(json_extract('$s', '\$.hooks'))) = 0 THEN
        json_remove('$s', '\$.hooks')
      ELSE '$s'
    END;
  "
}

apply_settings() {
  local type="$1"
  local project="$2"
  local mode="$3"

  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")
  mkdir -p "$(dirname "$hooks_file")"

  local settings_esc
  settings_esc=$(read_settings_escaped "$hooks_file")

  # 1) Strip any prior agmsg ownership from SessionStart, SessionEnd, Stop.
  settings_esc=$(strip_agmsg_event "$settings_esc" "SessionStart" | sed "s/'/''/g")
  settings_esc=$(strip_agmsg_event "$settings_esc" "SessionEnd"   | sed "s/'/''/g")
  settings_esc=$(strip_agmsg_event "$settings_esc" "Stop"         | sed "s/'/''/g")

  # 2) Re-add what this mode wants.
  case "$mode" in
    monitor)
      local ss="'$SKILL_DIR/scripts/session-start.sh' '$type' '$project'"
      local se="'$SKILL_DIR/scripts/session-end.sh'   '$type' '$project'"
      settings_esc=$(add_event_entry "$settings_esc" "SessionStart" "$ss" | sed "s/'/''/g")
      settings_esc=$(add_event_entry "$settings_esc" "SessionEnd"   "$se" | sed "s/'/''/g")
      ;;
    turn)
      local cmd="'$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'"
      settings_esc=$(add_event_entry "$settings_esc" "Stop" "$cmd" | sed "s/'/''/g")
      ;;
    both)
      local ss="'$SKILL_DIR/scripts/session-start.sh' '$type' '$project'"
      local se="'$SKILL_DIR/scripts/session-end.sh'   '$type' '$project'"
      local st="'$SKILL_DIR/scripts/check-inbox.sh'   '$type' '$project'"
      settings_esc=$(add_event_entry "$settings_esc" "SessionStart" "$ss" | sed "s/'/''/g")
      settings_esc=$(add_event_entry "$settings_esc" "SessionEnd"   "$se" | sed "s/'/''/g")
      settings_esc=$(add_event_entry "$settings_esc" "Stop"         "$st" | sed "s/'/''/g")
      ;;
    off)
      : # already stripped
      ;;
    *)
      echo "Unknown mode: $mode (use monitor|turn|both|off)" >&2
      return 1
      ;;
  esac

  settings_esc=$(prune_empty_hooks "$settings_esc")

  # Unescape for write.
  printf '%s' "$settings_esc" | sed "s/''/'/g" > "$hooks_file"
}

emit_monitor_directive() {
  local type="$1"
  local project="$2"
  local watch="$SKILL_DIR/scripts/watch.sh"
  cat <<EOF

AGMSG-DIRECTIVE: For this running session, invoke the Monitor tool now with:
  command: $watch \$AGMSG_SESSION_ID $project $type
  description: agmsg inbox stream
  persistent: true

Substitute \$AGMSG_SESSION_ID with the current session_id when known
(passed by the SessionStart hook in production; in interactive use, any
unique string per session works — the pidfile uses it as a key).
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

do_set() {
  local MODE="${1:?Usage: delivery.sh set <mode> <type> <project_path>}"
  local TYPE="${2:?Missing type}"
  local PROJECT="${3:?Missing project_path}"

  case "$MODE" in monitor|turn|both|off) ;; *)
    echo "Unknown mode: $MODE (use monitor|turn|both|off)" >&2; exit 1 ;;
  esac

  apply_settings "$TYPE" "$PROJECT" "$MODE"
  "$SCRIPT_DIR/config.sh" set delivery.mode "$MODE" >/dev/null

  echo "Delivery mode set to '$MODE' for $PROJECT ($TYPE)"

  case "$MODE" in
    monitor|both)
      echo "Future sessions: SessionStart hook will auto-launch the watcher."
      emit_monitor_directive "$TYPE" "$PROJECT"
      ;;
    turn)
      echo "Future sessions: Stop hook will check inbox between turns."
      # If a watcher is alive in this session, ask Claude to stop it.
      kill_all_watchers >/dev/null 2>&1 || true
      emit_stop_directive
      ;;
    off)
      echo "Future sessions: no automatic delivery."
      kill_all_watchers >/dev/null 2>&1 || true
      emit_stop_directive
      ;;
  esac
}

do_status() {
  local TYPE="${1:-}"
  local PROJECT="${2:-}"

  local mode
  mode=$("$SCRIPT_DIR/config.sh" get delivery.mode "" 2>/dev/null || true)
  if [ -z "$mode" ]; then
    # Legacy: if hook.check_interval exists from a prior hook.sh install,
    # treat that as effective mode=turn for reporting.
    local legacy
    legacy=$("$SCRIPT_DIR/config.sh" get hook.check_interval "" 2>/dev/null || true)
    if [ -n "$legacy" ]; then
      mode="turn (legacy hook.check_interval=$legacy)"
    else
      mode="off (default)"
    fi
  fi
  echo "mode: $mode"

  if [ -n "$TYPE" ] && [ -n "$PROJECT" ]; then
    local hooks_file
    hooks_file=$(resolve_hooks_file "$TYPE" "$PROJECT")
    if [ -f "$hooks_file" ]; then
      local count
      count=$(sqlite3 :memory: "SELECT json_array_length(json_extract('$(read_settings_escaped "$hooks_file")', '\$.hooks.SessionStart'));" 2>/dev/null || echo 0)
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      echo "settings hooks file: $hooks_file"
      echo "  SessionStart entries: $count"
      count=$(sqlite3 :memory: "SELECT json_array_length(json_extract('$(read_settings_escaped "$hooks_file")', '\$.hooks.SessionEnd'));" 2>/dev/null || echo 0)
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      echo "  SessionEnd entries:   $count"
      count=$(sqlite3 :memory: "SELECT json_array_length(json_extract('$(read_settings_escaped "$hooks_file")', '\$.hooks.Stop'));" 2>/dev/null || echo 0)
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      echo "  Stop entries:         $count"
    fi
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
  local killed=0
  if [ -d "$RUN_DIR" ]; then
    for f in "$RUN_DIR"/watch.*.pid; do
      [ -f "$f" ] || continue
      local pid
      pid=$(cat "$f" 2>/dev/null || echo "")
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null && killed=$((killed + 1))
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
