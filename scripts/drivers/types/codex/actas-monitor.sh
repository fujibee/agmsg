#!/usr/bin/env bash
set -euo pipefail

# Rebind Codex monitor delivery to an explicit actas identity.
#
# Usage:
#   actas-monitor.sh <project> <type> <name> [session_id]
#
# Codex has no Monitor tool. Monitor mode is implemented by a bridge process
# that watches one agmsg identity and wakes a Codex thread. Sessions launched
# through codex-monitor.sh use app-server; ordinary Codex.app sessions fall back
# to codex-app-monitor.sh, which wakes the Desktop thread via `codex exec resume`.
# actas must therefore start or rebind that receiver, otherwise sends use the new
# identity while receives keep watching the old one.

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
  project_hash="$(agmsg_sha1 <<<"$PROJECT")"
  state="$RUN_DIR/codex-last-actas.$project_hash.tsv"
  tmp="$state.$$"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$PROJECT" "$TYPE" "$TEAM" "$NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
  mv "$tmp" "$state"
}

record_last_actas

# actas means "make this role live now", so enable monitor mode if needed.
MODE="$("$SCRIPT_DIR/../../../delivery.sh" status "$TYPE" "$PROJECT" 2>/dev/null \
  | sed -n 's/^mode: //p')"
if [ "$MODE" != "monitor" ]; then
  "$SCRIPT_DIR/../../../delivery.sh" set monitor "$TYPE" "$PROJECT" >/dev/null
fi

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
  local meta pidfile pid meta_project meta_type meta_team meta_name
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
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile" "$meta"
  done
}

kill_receiver_files() {
  local pidfile="$1" meta="$2" pid
  local label
  if [ -f "$meta" ] && command -v launchctl >/dev/null 2>&1; then
    label="$(sed -n 's/^launch_label=//p' "$meta" | head -1)"
    if [ -n "$label" ]; then
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    fi
  fi
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile" "$meta"
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

write_codex_app_monitor_plist() {
  local plist="$1" label="$2" thread_id="$3" log="$4" tmp
  local codex_bin path_value
  if [ -x "/Applications/Codex.app/Contents/Resources/codex" ]; then
    codex_bin="/Applications/Codex.app/Contents/Resources/codex"
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
  <false/>
</dict>
</plist>
EOF
  mv "$tmp" "$plist"
}

start_codex_app_monitor() {
  local thread_id="$1"
  local pidfile log existing_pid existing_thread app_monitor_pid label plist domain
  if [ -z "$thread_id" ]; then
    actas_lock_gc_stale >/dev/null 2>&1 || true
    echo "status=no_thread team=$TEAM name=$NAME reason=codex_app_thread_id_unavailable"
    exit 8
  fi

  kill_other_project_receivers
  kill_receiver_files "$RUN_DIR/codex-bridge.$TEAM.$NAME.pid" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"

  pidfile="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.pid"
  log="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.log"
  label="$(codex_app_monitor_label)"
  plist="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.plist"
  domain="gui/$(id -u)"
  if [ -f "$pidfile" ]; then
    existing_pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      existing_thread="$(sed -n 's/^thread=//p' "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta" 2>/dev/null | head -1)"
      if [ "$existing_thread" = "$thread_id" ]; then
        echo "status=already_running team=$TEAM name=$NAME app_monitor_pid=$existing_pid thread=$thread_id transport=codex-app-exec-resume"
        exit 0
      fi
      kill_receiver_files "$pidfile" "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta"
    else
      rm -f "$pidfile" "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta"
    fi
  fi

  if command -v launchctl >/dev/null 2>&1 && launchctl print "$domain" >/dev/null 2>&1; then
    write_codex_app_monitor_plist "$plist" "$label" "$thread_id" "$log"
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    if ! launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1; then
      echo "status=app_monitor_failed team=$TEAM name=$NAME reason=launchctl_bootstrap_failed log=$log plist=$plist"
      exit 9
    fi
  else
    nohup "$SCRIPT_DIR/codex-app-monitor.sh" "$PROJECT" "$TYPE" "$TEAM" "$NAME" "$thread_id" >>"$log" 2>&1 &
  fi

  sleep 1.2
  app_monitor_pid="$(cat "$pidfile" 2>/dev/null || true)"
  if ! kill -0 "$app_monitor_pid" 2>/dev/null; then
    rm -f "$pidfile" "$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta"
    actas_lock_gc_stale >/dev/null 2>&1 || true
    echo "status=app_monitor_failed team=$TEAM name=$NAME log=$log"
    exit 9
  fi
  echo "status=ok team=$TEAM name=$NAME app_monitor_pid=$app_monitor_pid thread=$thread_id transport=codex-app-exec-resume"
  exit 0
}

THREAD_ID="${AGMSG_CODEX_ACTAS_THREAD:-}"
if [ -z "$THREAD_ID" ]; then
  THREAD_ID="$(resolve_thread_id || true)"
fi

port_alive() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

PROJECT_HASH="$(agmsg_sha1 <<<"$PROJECT")"
SERVER_LOG="$RUN_DIR/codex-app-server.$PROJECT_HASH.log"
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
    --inline-inbox
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
  # the Desktop owns them. Fall back to a new bridge-owned thread instead of
  # leaving actas with no receive side.
  rm -f "$BRIDGE_PIDFILE" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"
  printf 'actas-monitor: retrying without thread attach after failed thread=%s\n' "$THREAD_ID" >>"$BRIDGE_LOG"
  THREAD_ID="new"
  BRIDGE_PID="$(start_bridge "")"
  sleep 0.8
fi

if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
  echo "status=bridge_failed team=$TEAM name=$NAME log=$BRIDGE_LOG"
  exit 5
fi

READY_SECONDS="${AGMSG_CODEX_ACTAS_READY_SECONDS:-8}"
sleep "$READY_SECONDS"
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
  rm -f "$BRIDGE_PIDFILE" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"
  actas_lock_gc_stale >/dev/null 2>&1 || true
  echo "status=bridge_exited team=$TEAM name=$NAME log=$BRIDGE_LOG"
  exit 5
fi
case "$APP_SERVER" in
  ws://127.0.0.1:*)
    check_port="${APP_SERVER#ws://127.0.0.1:}"
    check_port="${check_port%%/*}"
    if ! port_alive "$check_port"; then
      rm -f "$BRIDGE_PIDFILE" "$RUN_DIR/codex-bridge.$TEAM.$NAME.meta"
      actas_lock_gc_stale >/dev/null 2>&1 || true
      echo "status=app_server_exited team=$TEAM name=$NAME app_server=$APP_SERVER log=$SERVER_LOG"
      exit 6
    fi
    ;;
esac

echo "status=ok team=$TEAM name=$NAME bridge_pid=$BRIDGE_PID app_server=$APP_SERVER thread=$THREAD_ID"
