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

resolve_hooks_file() {
  local type="$1"
  local project="$2"
  case "$type" in
    claude-code) echo "$project/.claude/settings.local.json" ;;
    codex)       echo "$project/.codex/hooks.json" ;;
    gemini|antigravity) echo "$project/.agent/rules/agmsg.md" ;;
    copilot)     echo "$project/.github/hooks/agmsg.json" ;;
    opencode)    echo "$project/.opencode/rules/agmsg.md" ;;
    *) echo "Unknown agent type: $type" >&2; return 1 ;;
  esac
}

sql_readfile_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    path=$(cygpath -w "$path" 2>/dev/null || printf '%s' "$path")
  fi
  printf '%s' "$path" | sed "s/'/''/g"
}

# Strip any agmsg-owned hook entries from <event> in the JSON at <path>. An
# entry is "agmsg-owned" when one of its inner hooks references a path under
# our skill directory. Result is written back to <path> atomically.
#
# Reads the settings via sqlite3's readfile() rather than interpolating the
# file's contents into the SQL string. The old in-memory chain embedded the
# settings blob 6× into a single sqlite3 argv element; on Linux that hits
# the per-arg MAX_ARG_STRLEN cap (131072 bytes) once the settings file
# crosses ~21 KB, so `delivery.sh set` failed with E2BIG (see #95). Using
# readfile() keeps the file off the argv entirely.
strip_agmsg_event_file() {
  local path="$1"
  local event="$2"
  local sql_path
  sql_path=$(sql_readfile_path "$path")
  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(sql_readfile_path "$tmp")
  # Write the result with writefile() rather than redirecting sqlite3's CLI
  # output. On strict sqlite3 builds (>= 3.50, shipped on Windows) the CLI
  # renders control bytes — e.g. a CR that rode in on a CRLF settings file —
  # using caret notation ("^M"), corrupting the JSON so the next read fails
  # with "malformed JSON" (#143/#138, same root cause as #102). writefile()
  # emits the bytes verbatim. See also strip's readfile() (#95).
  # Validate writefile()'s result, not just sqlite3's exit code. writefile()
  # returns the byte count written and yields NULL on a failed write (e.g. an
  # unwritable tmp dir) — but sqlite3 still exits 0, so an exit-code-only check
  # would mv an empty/partial tmp over the original. Compare the bytes written
  # to the content's byte length (CAST AS BLOB so multibyte content isn't
  # miscounted by character-based length()); anything but an exact match fails.
  # Guard contributed in #162 (kevinsj15).
  local wrote
  wrote=$(sqlite3 :memory: "
    WITH src AS (SELECT readfile('$sql_path') AS j),
    out AS (SELECT coalesce(CASE
      WHEN json_extract(src.j, '\$.hooks.$event') IS NULL THEN
        src.j
      WHEN (SELECT count(*) FROM json_each(json_extract(src.j, '\$.hooks.$event')) AS s
            WHERE NOT EXISTS (
              SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
              WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
            )) = 0 THEN
        json_remove(src.j, '\$.hooks.$event')
      ELSE
        json_set(src.j, '\$.hooks.$event',
          (SELECT json_group_array(json(s.value))
           FROM json_each(json_extract(src.j, '\$.hooks.$event')) AS s
           WHERE NOT EXISTS (
             SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
             WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
           ))
        )
    END, '') AS blob FROM src)
    SELECT writefile('$tmp_sql', blob) = length(CAST(blob AS BLOB)) FROM out;
  ") || { rm -f "$tmp"; return 1; }
  [ "$wrote" = "1" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path"
}

# Wrap a POSIX shell command so Codex's Windows runner executes it through Git
# Bash. On native Windows, Codex runs each hook command via PowerShell, which
# cannot execute a bare POSIX ".sh" path, so the hook exits non-zero. Codex hook
# config supports a "commandWindows" key that takes precedence on Windows.
windows_wrap() {
  local posix_cmd="$1"
  local bash_cmd_ps
  bash_cmd_ps=$(printf '%s' "$posix_cmd" | sed "s/'/''/g")
  printf "\$b=\$env:GIT_BASH; if (-not \$b) { \$b=\$env:AGMSG_BASH }; if (-not \$b) { \$b='C:\\\\Program Files\\\\Git\\\\bin\\\\bash.exe' }; & \$b -lc '%s'" "$bash_cmd_ps"
}

# Append a single entry of the form {"matcher":"","hooks":[{"type":"command","command":"<cmd>"}]}
# to .hooks.<event> in the JSON at <path>, creating arrays/objects as needed.
# For Codex agents (pass "codex" as the 4th arg) the entry also carries a
# "commandWindows" so the hook runs on native Windows; other agent types are
# unchanged. Writes the result back to <path>. As with strip_agmsg_event_file,
# the settings are read via readfile() rather than via argv (#95).
add_event_entry_file() {
  local path="$1"
  local event="$2"
  local cmd="$3"
  local hook_type="${4:-}"
  local sql_path
  sql_path=$(sql_readfile_path "$path")

  local hook_inner="\"type\":\"command\",\"command\":\"$cmd\""
  if [ "$hook_type" = "codex" ]; then
    local cw; cw=$(windows_wrap "$cmd")
    cw="${cw//\\/\\\\}"; cw="${cw//\"/\\\"}"
    hook_inner="$hook_inner,\"commandWindows\":\"$cw\""
  fi
  local entry="{\"matcher\":\"\",\"hooks\":[{$hook_inner}]}"
  local entry_esc
  entry_esc=$(printf '%s' "$entry" | sed "s/'/''/g")

  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(sql_readfile_path "$tmp")
  # writefile() instead of CLI redirect — see strip_agmsg_event_file for why
  # (strict sqlite3 caret-escapes control bytes in CLI output, #143/#102).
  # Validate writefile()'s byte count vs the content length — see
  # strip_agmsg_event_file for why the exit code alone is insufficient (#162).
  local wrote
  wrote=$(sqlite3 :memory: "
    WITH base AS (
      SELECT CASE WHEN json_extract(readfile('$sql_path'), '\$.hooks') IS NULL
                  THEN json_set(readfile('$sql_path'), '\$.hooks', json('{}'))
                  ELSE readfile('$sql_path') END AS s
    ),
    out AS (SELECT CASE
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
    END AS blob FROM base)
    SELECT writefile('$tmp_sql', blob) = length(CAST(blob AS BLOB)) FROM out;
  ") || { rm -f "$tmp"; return 1; }
  [ "$wrote" = "1" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path"
}

# Drop the entire .hooks object if it ended up empty after stripping. Reads
# and writes <path> via readfile() — see strip_agmsg_event_file for the
# rationale (#95).
prune_empty_hooks_file() {
  local path="$1"
  local sql_path
  sql_path=$(sql_readfile_path "$path")
  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(sql_readfile_path "$tmp")
  # writefile() instead of CLI redirect — see strip_agmsg_event_file (#143/#102).
  # Validate writefile()'s byte count vs the content length — see
  # strip_agmsg_event_file for why the exit code alone is insufficient (#162).
  local wrote
  wrote=$(sqlite3 :memory: "
    WITH src AS (SELECT readfile('$sql_path') AS j),
    out AS (SELECT coalesce(CASE
      WHEN json_extract(src.j, '\$.hooks') IS NULL THEN src.j
      WHEN (SELECT count(*) FROM json_each(json_extract(src.j, '\$.hooks'))) = 0 THEN
        json_remove(src.j, '\$.hooks')
      ELSE src.j
    END, '') AS blob FROM src)
    SELECT writefile('$tmp_sql', blob) = length(CAST(blob AS BLOB)) FROM out;
  ") || { rm -f "$tmp"; return 1; }
  [ "$wrote" = "1" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path"
}

apply_settings_opencode() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")

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

  rm -f "$rule_file"

  if [ "$mode" = "turn" ]; then
    mkdir -p "$(dirname "$rule_file")"
    cat <<EOF > "$rule_file"
# agmsg Integration Rule

## PostToolUse
After each tool call, automatically check the agmsg inbox for unread messages.
- Command: '$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'
EOF
  fi
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

  if [ "$type" = "opencode" ]; then
    apply_settings_opencode "$type" "$project" "$mode"
    return
  fi

  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")
  mkdir -p "$(dirname "$hooks_file")"

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
      add_event_entry_file "$tmp_state" "SessionStart" "$ss" "$type"
      add_event_entry_file "$tmp_state" "SessionEnd"   "$se" "$type"
      ;;
    turn)
      local cmd="'$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'"
      add_event_entry_file "$tmp_state" "Stop" "$cmd" "$type"
      ;;
    both)
      local ss="'$SKILL_DIR/scripts/session-start.sh' '$type' '$project'"
      local se="'$SKILL_DIR/scripts/session-end.sh'   '$type' '$project'"
      local st="'$SKILL_DIR/scripts/check-inbox.sh'   '$type' '$project'"
      add_event_entry_file "$tmp_state" "SessionStart" "$ss" "$type"
      add_event_entry_file "$tmp_state" "SessionEnd"   "$se" "$type"
      add_event_entry_file "$tmp_state" "Stop"         "$st" "$type"
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

  case "$MODE" in monitor|turn|both|off) ;; *)
    echo "Unknown mode: $MODE (use monitor|turn|both|off)" >&2; exit 1 ;;
  esac
  if [ "$TYPE" = "codex" ] && [ "$MODE" = "both" ]; then
    echo "Error: 'both' mode is not supported for codex bridge beta. Use 'monitor', 'turn', or 'off'." >&2
    exit 1
  fi

  apply_settings "$TYPE" "$PROJECT" "$MODE"

  echo "Delivery mode set to '$MODE' for $PROJECT ($TYPE)"

  case "$MODE" in
    monitor|both)
      if [ "$TYPE" = "codex" ]; then
        if AGMSG_CODEX_SHIM_INSTALL_QUIET=1 "$SKILL_DIR/scripts/codex-shim-install.sh" install; then
          echo "Codex monitor shim installed at ~/.agents/bin/codex."
          case ":$PATH:" in
            *":$HOME/.agents/bin:"*)
              echo "Future Codex sessions: launch with codex. In monitor-mode projects, the agmsg shim routes interactive Codex sessions through the bridge."
              ;;
            *)
              # Loud, unambiguous: this is the #1 reason monitor silently does nothing.
              echo "WARNING: ~/.agents/bin is NOT on your PATH, so 'codex' still launches the real"
              echo "  binary and the monitor bridge will NOT engage. Add this line, restart your shell,"
              echo "  then launch with codex:"
              echo "    export PATH=\"\$HOME/.agents/bin:\$PATH\""
              ;;
          esac
        else
          echo "Codex monitor mode is enabled, but the codex shim was not installed."
          echo "Future Codex sessions: launch with $SKILL_DIR/scripts/codex-monitor.sh, or resolve the shim install issue above."
        fi
        # Node preflight: the bridge (codex-bridge.js) is a Node program, so
        # without Node it silently never starts — flag it here at enable time.
        # Presence only: the bridge uses old/stable APIs (the sole modern feature
        # is one optional-chaining call, Node 14+), and any Node new enough to run
        # Codex itself runs the bridge — so a version gate would be noise.
        # AGMSG_CODEX_NODE overrides the binary the check looks for (also testable).
        codex_node="${AGMSG_CODEX_NODE:-node}"
        if ! command -v "$codex_node" >/dev/null 2>&1; then
          echo "WARNING: Node.js ('$codex_node') was not found on PATH. The Codex bridge needs Node —"
          echo "  monitor delivery will NOT start until Node is installed."
        fi
        # The bridge launches from the Codex SessionStart hook, which fires on the
        # FIRST turn of a new session (not the moment Codex opens) — and an
        # already-running session is not retrofitted (#151; launcher internals #153).
        echo "Restart your Codex session (quit and relaunch \`codex\`), then send your first"
        echo "  message — the bridge starts on your first turn, not the moment Codex opens."
        echo "  Already-running sessions stay unmonitored until they restart."
        echo "For more info: $CODEX_MONITOR_DOC_URL"
      else
        echo "Future sessions: SessionStart hook will auto-launch the watcher."
        emit_monitor_directive "$TYPE" "$PROJECT"
      fi
      ;;
    turn)
      echo "Future sessions: Stop hook will check inbox between turns."
      # Stop only THIS project's watcher; other projects/sessions keep theirs.
      kill_all_watchers "$PROJECT" >/dev/null 2>&1 || true
      emit_stop_directive
      ;;
    off)
      echo "Future sessions: no automatic delivery."
      if [ "$TYPE" = "codex" ]; then
        local stopped
        stopped=$(stop_codex_bridge "$PROJECT")
        if [ "${stopped:-0}" -gt 0 ]; then
          echo "Stopped $stopped Codex bridge process(es) for this project and cleaned their run files."
        fi
        echo "Note: the codex shim (~/.agents/bin/codex) is shared across projects, so it was left in place."
        echo "  If no other project uses monitor mode, remove it and restore your PATH:"
        echo "    $SKILL_DIR/scripts/codex-shim-install.sh remove"
        echo "    # then drop ~/.agents/bin from PATH if you added it for monitor"
      else
        kill_all_watchers "$PROJECT" >/dev/null 2>&1 || true
      fi
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
    if [ "$TYPE" = "gemini" ] || [ "$TYPE" = "antigravity" ] || [ "$TYPE" = "copilot" ] || [ "$TYPE" = "opencode" ]; then
      local mode="off"
      if [ -f "$hf" ]; then
        mode="turn"
      fi
      echo "mode: $mode"
    else
      local has_ss=0 has_st=0
      if [ -f "$hf" ]; then
        local sql_hf
        sql_hf=$(sql_readfile_path "$hf")
        has_ss=$(sqlite3 :memory: "
          SELECT EXISTS(
            SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.SessionStart')) AS s,
              json_each(json_extract(s.value, '\$.hooks')) AS h
            WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
          );" 2>/dev/null || echo 0)
        has_st=$(sqlite3 :memory: "
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
    fi
  fi

  if [ -n "$TYPE" ] && [ -n "$PROJECT" ] && [ "$TYPE" != "gemini" ] && [ "$TYPE" != "antigravity" ] && [ "$TYPE" != "copilot" ] && [ "$TYPE" != "opencode" ]; then
    local hooks_file
    hooks_file=$(resolve_hooks_file "$TYPE" "$PROJECT")
    if [ -f "$hooks_file" ]; then
      local count
      local sql_hooks_file
      sql_hooks_file=$(sql_readfile_path "$hooks_file")
      # readfile() rather than interpolating the file contents into argv —
      # for large settings (#95) the latter hits MAX_ARG_STRLEN on Linux.
      count=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$sql_hooks_file'), '\$.hooks.SessionStart'));" 2>/dev/null || echo 0)
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      echo "settings hooks file: $hooks_file"
      echo "  SessionStart entries: $count"
      count=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$sql_hooks_file'), '\$.hooks.SessionEnd'));" 2>/dev/null || echo 0)
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      echo "  SessionEnd entries:   $count"
      count=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$sql_hooks_file'), '\$.hooks.Stop'));" 2>/dev/null || echo 0)
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
