#!/usr/bin/env bash
set -euo pipefail

# Rebind Codex monitor delivery to an explicit actas identity.
#
# Usage:
#   actas-monitor.sh <project> <type> <name> [session_id]
#
# Codex has no native Monitor tool. An explicitly selected monitor/both mode
# binds one agmsg identity to a persisted Codex thread. A live app-server bridge
# is preferred; otherwise a shell-only watcher resumes that same thread only
# when unread mail exists. turn/off never start the background receiver.

PROJECT="${1:?Usage: actas-monitor.sh <project> <type> <name> [session_id]}"
TYPE="${2:?Missing type}"
NAME="${3:?Missing name}"
SESSION_ID="${4:-${CODEX_THREAD_ID:-}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"

# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
# shellcheck source=../../../lib/node.sh
source "$SCRIPT_DIR/../../../lib/node.sh"
# shellcheck source=../../../lib/compat.sh
source "$SCRIPT_DIR/../../../lib/compat.sh"
# shellcheck source=../../../lib/resolve-project.sh
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# shellcheck source=../../../lib/actas-lock.sh
source "$SCRIPT_DIR/../../../lib/actas-lock.sh"

PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"
mkdir -p "$RUN_DIR"

NODE_BIN="$(agmsg_resolve_node)"
TAB="$(printf '\t')"

find_identity() {
  "$SCRIPT_DIR/../../../identities.sh" "$PROJECT" "$TYPE" 2>/dev/null \
    | awk -v want="$NAME" -v tab="$TAB" 'NF >= 2 && $2 == want { print $1 tab $2 }' \
    | sort -u
}

IDS="$(find_identity || true)"
COUNT="$(printf '%s\n' "$IDS" | grep -c . || true)"
case "$COUNT" in
  0)
    echo "status=not_registered name=$NAME"
    exit 2
    ;;
  1)
    IFS="$TAB" read -r TEAM _agent <<EOF
$IDS
EOF
    ;;
  *)
    echo "status=multiple_teams name=$NAME"
    printf '%s\n' "$IDS" | awk -F "$TAB" '{ print "team=" $1 }'
    exit 3
    ;;
esac

if [ -n "$SESSION_ID" ]; then
  CURRENT_OWNER="$(agmsg_normalize_instance_id "$SESSION_ID" "$TYPE")"
  actas_lock_release "$TEAM" "$NAME" "$CURRENT_OWNER" 2>/dev/null || true
fi

record_last_actas() {
  local project_hash state tmp
  project_hash="$(printf '%s' "$PROJECT" | agmsg_sha1)"
  state="$RUN_DIR/codex-last-actas.$project_hash.tsv"
  tmp="$state.$$"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$PROJECT" "$TYPE" "$TEAM" "$NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
  mv "$tmp" "$state"
}

record_last_actas

MODE="$("$SCRIPT_DIR/../../../delivery.sh" status "$TYPE" "$PROJECT" 2>/dev/null \
  | sed -n 's/^mode: //p')"

resolve_thread_id() {
  if [ -n "${CODEX_THREAD_ID:-}" ]; then
    printf '%s\n' "$CODEX_THREAD_ID"
    return 0
  fi
  "$NODE_BIN" - "$PROJECT" <<'NODE'
const fs = require("fs");
const path = require("path");
const project = fs.realpathSync(process.argv[2]);
const root = path.join(process.env.HOME || "", ".codex", "sessions");
const files = [];
function walk(dir) {
  let entries = [];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full);
    } else if (entry.isFile() && /^rollout-.*\.jsonl$/.test(entry.name)) {
      try {
        files.push({ full, mtime: fs.statSync(full).mtimeMs });
      } catch {}
    }
  }
}
walk(root);
files.sort((a, b) => b.mtime - a.mtime);
for (const { full } of files.slice(0, 80)) {
  let first = "";
  try {
    first = fs.readFileSync(full, "utf8").split(/\r?\n/, 1)[0] || "";
  } catch {
    continue;
  }
  try {
    const row = JSON.parse(first);
    const payload = row && row.payload;
    if (!payload || !payload.cwd || !payload.id) continue;
    let cwd = "";
    try {
      cwd = fs.realpathSync(payload.cwd);
    } catch {
      cwd = path.resolve(payload.cwd);
    }
    if (cwd === project) {
      console.log(payload.id);
      process.exit(0);
    }
  } catch {}
}
NODE
}

kill_other_project_receivers() {
  local meta pidfile meta_project meta_type meta_team meta_name
  for meta in "$RUN_DIR"/codex-bridge.*.meta "$RUN_DIR"/codex-app-monitor.*.meta; do
    [ -f "$meta" ] || continue
    meta_project="$(sed -n 's/^project=//p' "$meta" | head -1)"
    meta_type="$(sed -n 's/^type=//p' "$meta" | head -1)"
    meta_team="$(sed -n 's/^team=//p' "$meta" | head -1)"
    meta_name="$(sed -n 's/^name=//p' "$meta" | head -1)"
    [ "$meta_project" = "$PROJECT" ] || continue
    [ "$meta_type" = "$TYPE" ] || continue
    [ "$meta_team" = "$TEAM" ] && [ "$meta_name" = "$NAME" ] && continue
    pidfile="${meta%.meta}.pid"
    kill_receiver_files "$pidfile" "$meta"
  done
}

wait_for_pid_exit() {
  local pid="$1" check=0 state
  while [ "$check" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "$state" in Z*) return 0 ;; esac
    sleep 0.1
    check=$((check + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || return 1
    check=0
    while [ "$check" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
      state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
      case "$state" in Z*) return 0 ;; esac
      sleep 0.1
      check=$((check + 1))
    done
  fi
  ! kill -0 "$pid" 2>/dev/null
}

kill_receiver_files() {
  local pidfile="$1" meta="$2" pid="" cmd="" label="" kind base plist
  base="${pidfile%.pid}"
  kind="${base##*/}"
  plist="$base.plist"
  if [ -f "$meta" ]; then
    label="$(sed -n 's/^launch_label=//p' "$meta" | head -1)"
  fi
  if [ -z "$label" ] && [ -f "$plist" ]; then
    label="$(awk '/<key>Label<\/key>/{getline; sub(/^[[:space:]]*<string>/, ""); sub(/<\/string>[[:space:]]*$/, ""); print; exit}' "$plist")"
  fi
  if [ -n "$label" ] && command -v launchctl >/dev/null 2>&1; then
    bootout_label_and_wait "gui/$(id -u)" "$label"
  fi
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
  fi
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
    case "$kind:$cmd" in
      codex-bridge.*:*codex-bridge.js*|codex-app-monitor.*:*codex-app-monitor.sh*)
        kill "$pid" 2>/dev/null || true
        if ! wait_for_pid_exit "$pid"; then
          echo "actas-monitor: receiver pid $pid did not stop; preserving its run files" >&2
          return 1
        fi
        ;;
    esac
  fi
  rm -f "$pidfile" "$meta" "$base.appserver" "$base.log" "$plist" \
    "$base.health" "$base.preflight.log" "$base.last-prompt.txt" \
    "$base.last-message.txt" "$base.last-status" "$base.last-ids" \
    "$base.watch-output"
}

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

plist_string() {
  printf '%s' "$1" | xml_escape
}

codex_app_monitor_label() {
  local safe_team safe_name
  safe_team="$(printf '%s' "$TEAM" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')"
  safe_name="$(printf '%s' "$NAME" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')"
  printf 'com.agmsg.codex-app-monitor.%s.%s.%s' "$PROJECT_HASH" "$safe_team" "$safe_name"
}

bootout_label_and_wait() {
  local domain="$1" label="$2" check=0
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  while [ "$check" -lt 20 ] && launchctl print "$domain/$label" >/dev/null 2>&1; do
    sleep 0.1
    check=$((check + 1))
  done
}

write_codex_app_monitor_plist() {
  local plist="$1" label="$2" thread_id="$3" log="$4" tmp
  local codex_bin path_value
  if [ -n "${AGMSG_CODEX_APP_MONITOR_CODEX:-}" ]; then
    codex_bin="$AGMSG_CODEX_APP_MONITOR_CODEX"
  elif [ -x "/Applications/ChatGPT.app/Contents/Resources/codex" ]; then
    codex_bin="/Applications/ChatGPT.app/Contents/Resources/codex"
  elif [ -x "/Applications/Codex.app/Contents/Resources/codex" ]; then
    codex_bin="/Applications/Codex.app/Contents/Resources/codex"
  elif [ -x "$HOME/.npm-global/bin/codex" ]; then
    codex_bin="$HOME/.npm-global/bin/codex"
  else
    codex_bin="$(command -v codex 2>/dev/null || true)"
  fi
  path_value="${PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
  tmp="$plist.$$"
  cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(plist_string "$label")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(plist_string "$SCRIPT_DIR/codex-app-monitor.sh")</string>
    <string>$(plist_string "$PROJECT")</string>
    <string>$(plist_string "$TYPE")</string>
    <string>$(plist_string "$TEAM")</string>
    <string>$(plist_string "$NAME")</string>
    <string>$(plist_string "$thread_id")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$(plist_string "$HOME")</string>
    <key>PATH</key>
    <string>$(plist_string "$path_value")</string>
    <key>AGMSG_CODEX_APP_MONITOR_LABEL</key>
    <string>$(plist_string "$label")</string>
    <key>AGMSG_CODEX_APP_MONITOR_CODEX</key>
    <string>$(plist_string "${codex_bin:-codex}")</string>
    <key>AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME</key>
    <string>1</string>
    <key>AGMSG_CODEX_APP_MONITOR_SUPERVISED</key>
    <string>1</string>
    <key>AGMSG_CODEX_APP_MONITOR_TIMEOUT</key>
    <string>$(plist_string "${AGMSG_CODEX_APP_MONITOR_TIMEOUT:-}")</string>
    <key>AGMSG_CODEX_APP_MONITOR_INTERVAL</key>
    <string>$(plist_string "${AGMSG_CODEX_APP_MONITOR_INTERVAL:-}")</string>
    <key>AGMSG_CODEX_APP_MONITOR_MAX_WAKES</key>
    <string>$(plist_string "${AGMSG_CODEX_APP_MONITOR_MAX_WAKES:-}")</string>
    <key>AGMSG_CODEX_APP_MONITOR_MAX_FAILURES</key>
    <string>$(plist_string "${AGMSG_CODEX_APP_MONITOR_MAX_FAILURES:-}")</string>
    <key>AGMSG_CODEX_APP_MONITOR_FLAGS</key>
    <string>$(plist_string "${AGMSG_CODEX_APP_MONITOR_FLAGS:-}")</string>
    <key>AGMSG_CODEX_APP_MONITOR_DISABLE_NOTIFY</key>
    <string>$(plist_string "${AGMSG_CODEX_APP_MONITOR_DISABLE_NOTIFY:-}")</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$(plist_string "$PROJECT")</string>
  <key>StandardOutPath</key>
  <string>$(plist_string "$log")</string>
  <key>StandardErrorPath</key>
  <string>$(plist_string "$log")</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>2</integer>
</dict>
</plist>
EOF
  mv "$tmp" "$plist"
}

start_codex_app_monitor() {
  local thread_id="$1"
  local pidfile log health existing_pid existing_thread existing_health app_monitor_pid label plist domain
  local health_status ready_seconds ready_checks check
  if [ -z "$thread_id" ]; then
    actas_lock_gc_stale >/dev/null 2>&1 || true
    start_chat_visible_turn_delivery "" "codex_app_thread_id_unavailable"
  fi

  kill_other_project_receivers
  kill_receiver_files "$RUN_DIR/codex-bridge.$TEAM.$NAME.pid" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"

  pidfile="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.pid"
  log="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.log"
  health="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.health"
  label="$(codex_app_monitor_label)"
  plist="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.plist"
  domain="gui/$(id -u)"
  if [ -f "$pidfile" ]; then
    existing_pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      existing_thread="$(sed -n 's/^thread=//p' "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta" 2>/dev/null | head -1)"
      existing_health="$(sed -n 's/^status=//p' "$health" 2>/dev/null | head -1 || true)"
      if [ "$existing_thread" = "$thread_id" ]; then
        echo "status=already_running team=$TEAM name=$NAME app_monitor_pid=$existing_pid thread=$thread_id transport=codex-background-thread-resume health=${existing_health:-unknown}"
        exit 0
      fi
      kill_receiver_files "$pidfile" "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta"
    else
      rm -f "$pidfile" "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta"
    fi
  fi
  rm -f "$health" "$RUN_DIR/codex-chat-visible.$TEAM.$NAME.meta"

  if command -v launchctl >/dev/null 2>&1 && launchctl print "$domain" >/dev/null 2>&1; then
    write_codex_app_monitor_plist "$plist" "$label" "$thread_id" "$log"
    bootout_label_and_wait "$domain" "$label"
    if ! launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1; then
      start_chat_visible_turn_delivery "$thread_id" "app_monitor_launchctl_bootstrap_failed"
    fi
  else
    nohup env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
      "$SCRIPT_DIR/codex-app-monitor.sh" "$PROJECT" "$TYPE" "$TEAM" "$NAME" "$thread_id" >>"$log" 2>&1 &
  fi

  ready_seconds="${AGMSG_CODEX_APP_MONITOR_READY_SECONDS:-5}"
  case "$ready_seconds" in ''|*[!0-9]*) ready_seconds=5 ;; esac
  [ "$ready_seconds" -gt 0 ] || ready_seconds=1
  ready_checks=$((ready_seconds * 5))
  check=0
  while [ "$check" -lt "$ready_checks" ]; do
    app_monitor_pid="$(cat "$pidfile" 2>/dev/null || true)"
    health_status="$(sed -n 's/^status=//p' "$health" 2>/dev/null | head -1 || true)"
    if [ "$health_status" = "ready" ] && [ -n "$app_monitor_pid" ] && kill -0 "$app_monitor_pid" 2>/dev/null; then
      echo "status=ok team=$TEAM name=$NAME app_monitor_pid=$app_monitor_pid thread=$thread_id transport=codex-background-thread-resume health=ready"
      exit 0
    fi
    case "$health_status" in preflight_failed|fallback_failed) break ;; esac
    if [ -n "$app_monitor_pid" ] && ! kill -0 "$app_monitor_pid" 2>/dev/null; then
      break
    fi
    sleep 0.2
    check=$((check + 1))
  done

  bootout_label_and_wait "$domain" "$label"
  rm -f "$pidfile" "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta"
  actas_lock_gc_stale >/dev/null 2>&1 || true
  start_chat_visible_turn_delivery "$thread_id" "app_monitor_${health_status:-not_ready}"
}

start_chat_visible_turn_delivery() {
  local thread_id="$1"
  local reason="${2:-foreground_turn_mode}"
  local meta="$RUN_DIR/codex-chat-visible.$TEAM.$NAME.meta"

  kill_other_project_receivers
  kill_receiver_files "$RUN_DIR/codex-bridge.$TEAM.$NAME.pid" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"
  kill_receiver_files "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.pid" "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta"

  {
    printf 'project=%s\n' "$PROJECT"
    printf 'type=%s\n' "$TYPE"
    printf 'team=%s\n' "$TEAM"
    printf 'name=%s\n' "$NAME"
    printf 'thread=%s\n' "${thread_id:-unresolved}"
    printf 'transport=codex-chat-visible-turn\n'
    printf 'status=waiting_for_chat_turn\n'
    printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$meta"

  echo "status=visible_turn_only team=$TEAM name=$NAME thread=${thread_id:-unresolved} transport=codex-chat-visible-turn reason=$reason"
  exit 0
}

THREAD_ID="${AGMSG_CODEX_ACTAS_THREAD:-}"
if [ -z "$THREAD_ID" ]; then
  THREAD_ID="$(resolve_thread_id || true)"
fi

case "$MODE" in
  monitor|both)
    ;;
  turn)
    start_chat_visible_turn_delivery "$THREAD_ID" "foreground_turn_mode"
    ;;
  off|"")
    kill_other_project_receivers
    kill_receiver_files "$RUN_DIR/codex-bridge.$TEAM.$NAME.pid" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"
    kill_receiver_files "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.pid" "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta"
    echo "status=receive_disabled team=$TEAM name=$NAME mode=${MODE:-off}"
    exit 0
    ;;
  *)
    echo "status=invalid_mode team=$TEAM name=$NAME mode=$MODE" >&2
    exit 4
    ;;
esac

port_alive() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

PROJECT_HASH="$(agmsg_sha1 <<<"$PROJECT")"
SERVER_PID="$RUN_DIR/codex-app-server.$PROJECT_HASH.pid"
PORT_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.port"

APP_SERVER="${AGMSG_CODEX_BRIDGE_APP_SERVER:-}"
if [ -z "$APP_SERVER" ] && [ -f "$PORT_FILE" ] && [ -f "$SERVER_PID" ]; then
  existing_port="$(cat "$PORT_FILE" 2>/dev/null || true)"
  existing_pid="$(cat "$SERVER_PID" 2>/dev/null || true)"
  if [ -n "$existing_port" ] && [ -n "$existing_pid" ] \
      && kill -0 "$existing_pid" 2>/dev/null && port_alive "$existing_port"; then
    APP_SERVER="ws://127.0.0.1:$existing_port"
  fi
fi

if [ -z "$APP_SERVER" ]; then
  start_codex_app_monitor "$THREAD_ID"
fi

if [ -z "$THREAD_ID" ]; then
  THREAD_ID="loaded"
fi

kill_other_project_receivers
kill_receiver_files "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.pid" "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta"

BRIDGE_PIDFILE="$RUN_DIR/codex-bridge.$TEAM.$NAME.pid"
BRIDGE_LOG="$RUN_DIR/codex-bridge.$TEAM.$NAME.log"
if [ -f "$BRIDGE_PIDFILE" ]; then
  existing_bridge="$(cat "$BRIDGE_PIDFILE" 2>/dev/null || true)"
  if [ -n "$existing_bridge" ] && kill -0 "$existing_bridge" 2>/dev/null; then
    echo "status=already_running team=$TEAM name=$NAME bridge_pid=$existing_bridge app_server=$APP_SERVER thread=$THREAD_ID"
    exit 0
  fi
  rm -f "$BRIDGE_PIDFILE" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"
fi

start_bridge() {
  local thread_id="$1"
  local args=(
    "$SCRIPT_DIR/codex-bridge.js"
    --project "$PROJECT"
    --type "$TYPE"
    --team "$TEAM"
    --name "$NAME"
    --app-server "$APP_SERVER"
  )
  if [ -n "$thread_id" ]; then
    args+=(--thread "$thread_id")
  fi
  nohup "$NODE_BIN" "${args[@]}" >>"$BRIDGE_LOG" 2>&1 &
  echo "$!"
}

BRIDGE_PID="$(start_bridge "$THREAD_ID")"

sleep 0.8
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
  # Codex Desktop rollouts can be unreadable to a standalone app-server while
  # the Desktop owns them. Never retry without a thread: thread/start would
  # create a new Codex task. Preserve a concrete thread through the explicit
  # background receiver, or fall back to foreground turn delivery when the
  # loaded thread could not be resolved.
  rm -f "$BRIDGE_PIDFILE" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"
  printf 'actas-monitor: thread attach failed; refusing thread/start for thread=%s\n' "$THREAD_ID" >>"$BRIDGE_LOG"
  case "$THREAD_ID" in
    ""|loaded) start_chat_visible_turn_delivery "$THREAD_ID" "app_server_thread_attach_failed" ;;
    *) start_codex_app_monitor "$THREAD_ID" ;;
  esac
fi

READY_SECONDS="${AGMSG_CODEX_ACTAS_READY_SECONDS:-8}"
sleep "$READY_SECONDS"
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
  rm -f "$BRIDGE_PIDFILE" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"
  actas_lock_gc_stale >/dev/null 2>&1 || true
  case "$THREAD_ID" in
    ""|loaded) start_chat_visible_turn_delivery "$THREAD_ID" "app_server_bridge_exited" ;;
    *) start_codex_app_monitor "$THREAD_ID" ;;
  esac
fi
case "$APP_SERVER" in
  ws://127.0.0.1:*)
    check_port="${APP_SERVER#ws://127.0.0.1:}"
    check_port="${check_port%%/*}"
    if ! port_alive "$check_port"; then
      rm -f "$BRIDGE_PIDFILE" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"
      actas_lock_gc_stale >/dev/null 2>&1 || true
      case "$THREAD_ID" in
        ""|loaded) start_chat_visible_turn_delivery "$THREAD_ID" "app_server_exited" ;;
        *) start_codex_app_monitor "$THREAD_ID" ;;
      esac
    fi
    ;;
esac

echo "status=ok team=$TEAM name=$NAME bridge_pid=$BRIDGE_PID app_server=$APP_SERVER thread=$THREAD_ID"
