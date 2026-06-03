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
    gemini|antigravity) echo "$project/.agent/rules/agmsg.md" ;;
    copilot)     echo "$project/.github/hooks/agmsg.json" ;;
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

apply_settings_copilot() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")

  # Validate the mode BEFORE touching any existing file. Rejecting
  # monitor/both must not destroy a working turn hook.
  case "$mode" in
    turn|off) ;;
    monitor|both)
      echo "Error: '$mode' mode is not supported for $type (no Monitor-tool equivalent). Use 'turn' or 'off'." >&2
      return 1
      ;;
    *)
      echo "Unknown mode: $mode (use turn|off)" >&2
      return 1
      ;;
  esac

  # Strip first so re-applying turn is an idempotent rewrite and turn->off
  # cleanly removes the file.
  rm -f "$hooks_file"

  if [ "$mode" = "turn" ]; then
    mkdir -p "$(dirname "$hooks_file")"
    local cmd="'$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'"
    # json_quote handles JSON-string escaping for arbitrary command strings
    # (project paths may contain JSON-special chars).
    local cmd_json
    cmd_json=$(sqlite3 :memory: "SELECT json_quote('$(printf '%s' "$cmd" | sed "s/'/''/g")');")
    # Use PascalCase 'Stop' trigger so the input payload field names match
    # the snake_case form (session_id) that check-inbox.sh already parses.
    cat <<EOF > "$hooks_file"
{
  "version": 1,
  "hooks": {
    "Stop": [
      {
        "type": "command",
        "bash": $cmd_json,
        "timeoutSec": 30
      }
    ]
  }
}
EOF
  fi
}

apply_settings_gemini() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")

  # Remove existing rule file
  rm -f "$rule_file"

  case "$mode" in
    turn|both)
      mkdir -p "$(dirname "$rule_file")"
      cat <<EOF > "$rule_file"
# agmsg Integration Rule

## PostToolUse
After each tool call, automatically check the agmsg inbox for unread messages.
- Command: '$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'
EOF
      ;;
    monitor)
      echo "Warning: 'monitor' mode is not fully supported for $type yet. Using turn-based hook." >&2
      apply_settings_gemini "$type" "$project" "turn"
      ;;
    off)
      ;;
  esac
}

apply_settings() {
  local type="$1"
  local project="$2"
  local mode="$3"

  if [ "$type" = "gemini" ] || [ "$type" = "antigravity" ]; then
    apply_settings_gemini "$type" "$project" "$mode"
    return
  fi

  if [ "$type" = "copilot" ]; then
    apply_settings_copilot "$type" "$project" "$mode"
    return
  fi

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

  cat <<EOF

AGMSG-DIRECTIVE: For this running session, invoke the Monitor tool now with:
  command: $watch $session_id $project $type
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

do_set() {
  local MODE="${1:?Usage: delivery.sh set <mode> <type> <project_path>}"
  local TYPE="${2:?Missing type}"
  local PROJECT="${3:?Missing project_path}"

  case "$MODE" in monitor|turn|both|off) ;; *)
    echo "Unknown mode: $MODE (use monitor|turn|both|off)" >&2; exit 1 ;;
  esac

  apply_settings "$TYPE" "$PROJECT" "$MODE"

  echo "Delivery mode set to '$MODE' for $PROJECT ($TYPE)"

  case "$MODE" in
    monitor|both)
      echo "Future sessions: SessionStart hook will auto-launch the watcher."
      emit_monitor_directive "$TYPE" "$PROJECT"
      ;;
    turn)
      echo "Future sessions: Stop hook will check inbox between turns."
      # Stop only THIS project's watcher; other projects/sessions keep theirs.
      kill_all_watchers "$PROJECT" >/dev/null 2>&1 || true
      emit_stop_directive
      ;;
    off)
      echo "Future sessions: no automatic delivery."
      kill_all_watchers "$PROJECT" >/dev/null 2>&1 || true
      emit_stop_directive
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
  if [ -n "$TYPE" ] && [ -n "$PROJECT" ]; then
    local hf
    hf=$(resolve_hooks_file "$TYPE" "$PROJECT")
    if [ "$TYPE" = "gemini" ] || [ "$TYPE" = "antigravity" ] || [ "$TYPE" = "copilot" ]; then
      local mode="off"
      if [ -f "$hf" ]; then
        mode="turn"
      fi
      echo "mode: $mode"
    else
      local has_ss=0 has_st=0
      if [ -f "$hf" ]; then
        has_ss=$(sqlite3 :memory: "
          SELECT EXISTS(
            SELECT 1 FROM json_each(json_extract(readfile('$hf'), '\$.hooks.SessionStart')) AS s,
              json_each(json_extract(s.value, '\$.hooks')) AS h
            WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
          );" 2>/dev/null || echo 0)
        has_st=$(sqlite3 :memory: "
          SELECT EXISTS(
            SELECT 1 FROM json_each(json_extract(readfile('$hf'), '\$.hooks.Stop')) AS s,
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
    fi
  fi

  if [ -n "$TYPE" ] && [ -n "$PROJECT" ] && [ "$TYPE" != "gemini" ] && [ "$TYPE" != "antigravity" ] && [ "$TYPE" != "copilot" ]; then
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
