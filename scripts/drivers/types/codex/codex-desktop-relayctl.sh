#!/usr/bin/env bash
set -euo pipefail
umask 077

# Install and inspect the single per-user relay shared by Codex Desktop and
# role-scoped agmsg bridges. Capabilities live only in private runtime files;
# status, logs, argv, and the LaunchAgent plist expose redacted endpoints.

ACTION="${1:-status}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="${AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR:-$SKILL_DIR/run}"
HOST="${AGMSG_CODEX_DESKTOP_RELAY_HOST:-127.0.0.1}"
PORT="${AGMSG_CODEX_DESKTOP_RELAY_PORT:-49643}"
LABEL="com.agmsg.codex-desktop-relay"
DOMAIN="gui/$(id -u)"
PLIST_DIR="${AGMSG_CODEX_DESKTOP_RELAY_PLIST_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$PLIST_DIR/$LABEL.plist"
HEALTH="$RUN_DIR/codex-desktop-relay.health"
PIDFILE="$RUN_DIR/codex-desktop-relay.pid"
PORT_FILE="$RUN_DIR/codex-desktop-relay.port"
LOG="$RUN_DIR/codex-desktop-relay.log"
DESKTOP_TOKEN_FILE="$RUN_DIR/codex-desktop-relay.desktop-token"
BRIDGE_TOKEN_FILE="$RUN_DIR/codex-desktop-relay.bridge-token"
DESKTOP_ENDPOINT_FILE="$RUN_DIR/codex-desktop-relay.desktop-endpoint"
BRIDGE_ENDPOINT_FILE="$RUN_DIR/codex-desktop-relay.bridge-endpoint"
PRIOR_DESKTOP_ENDPOINT_FILE="$RUN_DIR/codex-desktop-relay.prior-desktop-endpoint"

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

plist_string() {
  printf '%s' "$1" | xml_escape
}

validate_port() {
  case "$PORT" in ''|*[!0-9]*) return 1 ;; esac
  [ "$PORT" -gt 0 ] && [ "$PORT" -le 65535 ]
}

generate_capability() {
  local file="$1" temporary value="" mode=""
  mkdir -p "$RUN_DIR"
  if [ -L "$file" ]; then
    rm -f "$file"
  elif [ -f "$file" ]; then
    mode="$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || true)"
    value="$(cat "$file" 2>/dev/null || true)"
    if [ "$mode" = "600" ] && printf '%s' "$value" | grep -Eq '^[a-f0-9]{64}$'; then
      return 0
    fi
    rm -f "$file"
  elif [ -e "$file" ]; then
    rm -rf "$file"
  fi
  value="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s' "$value" | grep -Eq '^[a-f0-9]{64}$' || {
    echo "codex-desktop-relayctl: capability generation failed" >&2
    exit 1
  }
  temporary="$file.$$"
  (umask 077; printf '%s\n' "$value" > "$temporary")
  chmod 600 "$temporary"
  mv "$temporary" "$file"
}

write_private_endpoints() {
  local desktop_token bridge_token temporary
  desktop_token="$(cat "$DESKTOP_TOKEN_FILE")"
  bridge_token="$(cat "$BRIDGE_TOKEN_FILE")"
  temporary="$DESKTOP_ENDPOINT_FILE.$$"
  (umask 077; printf 'ws://%s:%s/desktop/%s\n' "$HOST" "$PORT" "$desktop_token" > "$temporary")
  chmod 600 "$temporary"
  mv "$temporary" "$DESKTOP_ENDPOINT_FILE"
  temporary="$BRIDGE_ENDPOINT_FILE.$$"
  (umask 077; printf 'ws://%s:%s/bridge/%s\n' "$HOST" "$PORT" "$bridge_token" > "$temporary")
  chmod 600 "$temporary"
  mv "$temporary" "$BRIDGE_ENDPOINT_FILE"
}

prepare_private_runtime() {
  generate_capability "$DESKTOP_TOKEN_FILE"
  generate_capability "$BRIDGE_TOKEN_FILE"
  if [ "$(cat "$DESKTOP_TOKEN_FILE")" = "$(cat "$BRIDGE_TOKEN_FILE")" ]; then
    rm -f "$BRIDGE_TOKEN_FILE"
    generate_capability "$BRIDGE_TOKEN_FILE"
  fi
  write_private_endpoints
}

write_plist() {
  local temporary path_value
  mkdir -p "$PLIST_DIR" "$RUN_DIR"
  : > "$LOG"
  chmod 600 "$LOG"
  temporary="$PLIST.$$"
  path_value="${PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
  cat > "$temporary" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(plist_string "$LABEL")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(plist_string "$SCRIPT_DIR/codex-desktop-relay-run.sh")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$(plist_string "$HOME")</string>
    <key>PATH</key>
    <string>$(plist_string "$path_value")</string>
    <key>AGMSG_CODEX_DESKTOP_RELAY_HOST</key>
    <string>$(plist_string "$HOST")</string>
    <key>AGMSG_CODEX_DESKTOP_RELAY_PORT</key>
    <string>$(plist_string "$PORT")</string>
    <key>AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR</key>
    <string>$(plist_string "$RUN_DIR")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>2</integer>
  <key>StandardOutPath</key>
  <string>$(plist_string "$LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(plist_string "$LOG")</string>
</dict>
</plist>
EOF
  chmod 600 "$temporary"
  mv "$temporary" "$PLIST"
}

bootout() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
}

relay_pid_matches() {
  local pid="$1" cmd expected
  cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  expected="$SCRIPT_DIR/codex-desktop-relay.js --host $HOST --port $PORT --desktop-token-file $DESKTOP_TOKEN_FILE --bridge-token-file $BRIDGE_TOKEN_FILE --health $HEALTH --port-file $PORT_FILE --pid-file $PIDFILE --parent-pid "
  case " $cmd " in *" $expected"*) return 0 ;; esac
  return 1
}

port_owned_by_other_process() {
  command -v lsof >/dev/null 2>&1 || return 1
  local own_pid listeners pid
  own_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  listeners="$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
  [ -n "$listeners" ] || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if [ -n "$own_pid" ] && [ "$pid" = "$own_pid" ] \
        && relay_pid_matches "$pid"; then
      continue
    fi
    return 0
  done <<< "$listeners"
  return 1
}

desktop_env_is_owned() {
  local value="$1" expected="${2:-}" prefix token
  [ -n "$value" ] || return 1
  [ -z "$expected" ] || [ "$value" != "$expected" ] || return 0
  prefix="ws://$HOST:$PORT/desktop/"
  case "$value" in
    "$prefix"*) token="${value#"$prefix"}" ;;
    *) return 1 ;;
  esac
  printf '%s' "$token" | grep -Eq '^[a-f0-9]{64}$'
}

status() {
  local pid="" health_status="" display_status="" health_pid="" health_port="" primary="" initialized="" actual_port=""
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  health_status="$(sed -n 's/^status=//p' "$HEALTH" 2>/dev/null | head -1 || true)"
  health_pid="$(sed -n 's/^pid=//p' "$HEALTH" 2>/dev/null | head -1 || true)"
  health_port="$(sed -n 's/^port=//p' "$HEALTH" 2>/dev/null | head -1 || true)"
  primary="$(sed -n 's/^primary_connected=//p' "$HEALTH" 2>/dev/null | head -1 || true)"
  initialized="$(sed -n 's/^upstream_initialized=//p' "$HEALTH" 2>/dev/null | head -1 || true)"
  actual_port="$(cat "$PORT_FILE" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
      && relay_pid_matches "$pid" && [ "$health_pid" = "$pid" ] \
      && [ "$health_port" = "$actual_port" ] && [ "$actual_port" = "$PORT" ] \
      && [ -n "$health_status" ] && [ "$health_status" != "failed" ] \
      && [ "$health_status" != "stopped" ]; then
    display_status="$health_status"
    if [ "$display_status" = "ready" ] \
        && { [ "$primary" != "1" ] || [ "$initialized" != "1" ]; }; then
      display_status="waiting_for_desktop"
    fi
    printf 'status=%s pid=%s app_server=ws://%s:%s/<capability> primary_connected=%s upstream_initialized=%s\n' \
      "${display_status:-running}" "$pid" "$HOST" "${actual_port:-$PORT}" "${primary:-0}" "${initialized:-0}"
    return 0
  fi
  printf 'status=not_running app_server=ws://%s:%s/<capability>\n' "$HOST" "$PORT"
  return 1
}

restore_file() {
  local backup_dir="$1" file="$2" name
  name="$(basename "$file")"
  if [ -e "$backup_dir/$name" ]; then
    cp -p "$backup_dir/$name" "$file"
  else
    rm -f "$file"
  fi
}

enable_relay() {
  local backup_dir prior_env existing_endpoint had_plist=0 file temporary
  if port_owned_by_other_process; then
    echo "codex-desktop-relayctl: port $PORT is already owned by another listener" >&2
    return 1
  fi
  mkdir -p "$RUN_DIR" "$PLIST_DIR"
  backup_dir="$(mktemp -d "$RUN_DIR/.relayctl.rollback.XXXXXX")"
  prior_env="$(launchctl getenv CODEX_APP_SERVER_WS_URL 2>/dev/null || true)"
  if [ -f "$PLIST" ]; then
    cp -p "$PLIST" "$backup_dir/$(basename "$PLIST")"
    had_plist=1
  fi
  for file in "$DESKTOP_TOKEN_FILE" "$BRIDGE_TOKEN_FILE" "$DESKTOP_ENDPOINT_FILE" \
      "$BRIDGE_ENDPOINT_FILE" "$PRIOR_DESKTOP_ENDPOINT_FILE"; do
    [ ! -f "$file" ] || cp -p "$file" "$backup_dir/$(basename "$file")"
  done

  existing_endpoint="$(cat "$DESKTOP_ENDPOINT_FILE" 2>/dev/null || true)"
  if [ ! -f "$PRIOR_DESKTOP_ENDPOINT_FILE" ]; then
    temporary="$PRIOR_DESKTOP_ENDPOINT_FILE.$$"
    if desktop_env_is_owned "$prior_env" "$existing_endpoint"; then
      (umask 077; : > "$temporary")
    else
      (umask 077; printf '%s\n' "$prior_env" > "$temporary")
    fi
    chmod 600 "$temporary"
    mv "$temporary" "$PRIOR_DESKTOP_ENDPOINT_FILE"
  fi

  prepare_private_runtime
  write_plist
  bootout
  rm -f "$PIDFILE" "$PORT_FILE" "$HEALTH"
  if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
    :
  else
    launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
      if status >/dev/null 2>&1; then
        if launchctl setenv CODEX_APP_SERVER_WS_URL "$(cat "$DESKTOP_ENDPOINT_FILE")"; then
          rm -rf "$backup_dir"
          status
          return 0
        fi
        break
      fi
      sleep 0.1
    done
  fi

  bootout
  for file in "$DESKTOP_TOKEN_FILE" "$BRIDGE_TOKEN_FILE" "$DESKTOP_ENDPOINT_FILE" \
      "$BRIDGE_ENDPOINT_FILE" "$PRIOR_DESKTOP_ENDPOINT_FILE"; do
    restore_file "$backup_dir" "$file"
  done
  if [ "$had_plist" -eq 1 ]; then
    restore_file "$backup_dir" "$PLIST"
  else
    rm -f "$PLIST"
  fi
  rm -f "$PIDFILE" "$PORT_FILE" "$HEALTH"
  if [ -n "$prior_env" ]; then
    launchctl setenv CODEX_APP_SERVER_WS_URL "$prior_env" >/dev/null 2>&1 || true
  else
    launchctl unsetenv CODEX_APP_SERVER_WS_URL >/dev/null 2>&1 || true
  fi
  if [ "$had_plist" -eq 1 ]; then
    launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
    launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi
  rm -rf "$backup_dir"
  echo "codex-desktop-relayctl: relay did not start; see $LOG" >&2
  return 1
}

case "$ACTION" in
  enable|start)
    if [ "$(uname -s)" != "Darwin" ] || ! command -v launchctl >/dev/null 2>&1; then
      echo "codex-desktop-relayctl: Codex Desktop relay currently requires macOS launchctl" >&2
      exit 2
    fi
    validate_port || { echo "codex-desktop-relayctl: invalid port: $PORT" >&2; exit 2; }
    enable_relay
    ;;
  status)
    status
    ;;
  disable|stop|remove)
    if command -v launchctl >/dev/null 2>&1; then
      bootout
      current="$(launchctl getenv CODEX_APP_SERVER_WS_URL 2>/dev/null || true)"
      expected="$(cat "$DESKTOP_ENDPOINT_FILE" 2>/dev/null || true)"
      if desktop_env_is_owned "$current" "$expected"; then
        prior="$(cat "$PRIOR_DESKTOP_ENDPOINT_FILE" 2>/dev/null || true)"
        if [ -n "$prior" ]; then
          launchctl setenv CODEX_APP_SERVER_WS_URL "$prior"
        else
          launchctl unsetenv CODEX_APP_SERVER_WS_URL
        fi
      fi
    fi
    rm -f "$PLIST" "$PIDFILE" "$PORT_FILE" "$HEALTH" \
      "$DESKTOP_TOKEN_FILE" "$BRIDGE_TOKEN_FILE" "$DESKTOP_ENDPOINT_FILE" \
      "$BRIDGE_ENDPOINT_FILE" "$PRIOR_DESKTOP_ENDPOINT_FILE"
    printf 'status=stopped app_server=ws://%s:%s/<capability>\n' "$HOST" "$PORT"
    ;;
  *)
    echo "Usage: codex-desktop-relayctl.sh enable|status|disable" >&2
    exit 2
    ;;
esac
