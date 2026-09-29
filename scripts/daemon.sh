#!/usr/bin/env bash
# agmsgd's CLI (T4's diagram: "agmsg daemon start|stop|status|enable|
# disable"). Written to take the subcommand as its own first argument so
# the future `agmsg` dispatcher (a separate PR/design, decided 2026-09-29)
# can wrap this file directly without restructuring it. Every message this
# file prints therefore already says `agmsg daemon ...`, the form users
# will actually type once that dispatcher exists.
#
# No Node required for `status` on the fast path (T2 #6, K14): it reads
# install.db directly with sqlite3 first, and only shells out to Node
# (status.mjs) for the fuller decision text when Node is available and
# the record even suggests it's worth asking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DB="$SKILL_DIR/run/install.db"
LOCK_DB="$SKILL_DIR/run/install-op.lock.db"
LAUNCHER="$SCRIPT_DIR/daemon/agmsgd-launch.sh"

_usage() {
  cat >&2 <<'EOF'
usage: agmsg daemon start|stop|status|enable|disable
EOF
}

_require_install_db() {
  if [ ! -f "$INSTALL_DB" ]; then
    echo "agmsg daemon: run/install.db does not exist -- run install.sh first" >&2
    exit 1
  fi
}

# Runs $1 (one or more SQL statements against install.db's tables,
# unqualified names -- see below) inside the operation lock (T3 "持つ範
# 囲": start/enable/disable/uninstall take it for the whole operation;
# this helper is for the WRITE itself, callers still do their own pre/post
# work like waiting for ready outside it).
#
# The EXCLUSIVE lock belongs to $LOCK_DB (an empty file, PR 2's own
# design -- the lock IS the file, nothing is ever written into it
# directly). $1's statements target install.db, so install.db is ATTACHed
# into the SAME connection/transaction that holds the lock: a bare
# `sqlite3 "$LOCK_DB" "...UPDATE daemon_intent..."` would run that UPDATE
# against $LOCK_DB itself, which has no such table at all -- caught
# exactly this way while testing (`no such table: daemon_intent` even
# though install.db plainly has the table). ATTACH keeps the lock where
# PR 2 says it lives while still writing to the file that actually holds
# the data, in one real cross-file transaction.
_with_op_lock() {
  sqlite3 "$LOCK_DB" "ATTACH DATABASE '$(printf '%s' "$INSTALL_DB" | sed "s/'/''/g")' AS installdb; BEGIN EXCLUSIVE; $1 COMMIT;"
}

# A short, stable id for this install's resident-manager unit name,
# derived from the install anchor (realpath + install_id) -- T3 "常駐の登
# 録": "単位の名前の短いidはinstallの錨の3つの組から作る". Beta uses two
# of the three (root path, install_id); the record DB's own path is
# already implied by being run/install.db under this same root, so it is
# not a third independent input here.
_unit_id() {
  local install_id
  install_id="$(sqlite3 "$INSTALL_DB" "SELECT install_id FROM meta;" 2>/dev/null)"
  printf '%s:%s' "$SKILL_DIR" "$install_id" | shasum -a 256 | cut -c1-12
}

_os() {
  case "$(uname -s)" in
    Darwin) echo darwin ;;
    Linux) echo linux ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

# ---------------------------------------------------------------------------
# Resident registration (T3 "常駐の登録"). One function per OS; enable/
# disable call whichever applies. Only the darwin path has been run for
# real in this environment -- linux (systemd --user) and windows (Task
# Scheduler) are written to the same contract and shellchecked, but need
# their own hands-on confirmation on those platforms (T6 #3: "CIではなく
# 手で"), flagged in the PR rather than claimed here.
# ---------------------------------------------------------------------------

_launchd_label() { printf 'cc.agmsg.agmsgd.%s' "$(_unit_id)"; }
_launchd_plist_path() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(_launchd_label)"; }

_register_darwin() {
  local node_path="$1" label plist
  label="$(_launchd_label)"
  plist="$(_launchd_plist_path)"
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$LAUNCHER</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardErrorPath</key><string>$SKILL_DIR/run/agmsgd.stderr.log</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load "$plist"
}

_unregister_darwin() {
  local label plist
  label="$(_launchd_label)"
  plist="$(_launchd_plist_path)"
  if [ -f "$plist" ]; then
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
  fi
}

_systemd_unit_path() { printf '%s/.config/systemd/user/agmsgd-%s.service' "$HOME" "$(_unit_id)"; }

# NOT YET RUN ON LINUX in this environment -- written to T3's own table
# (Restart=on-failure, RestartSec=30s, StartLimitIntervalSec=600,
# StartLimitBurst=5) and shellchecked only.
_register_linux() {
  local unit_path unit_name
  unit_path="$(_systemd_unit_path)"
  unit_name="$(basename "$unit_path")"
  mkdir -p "$(dirname "$unit_path")"
  cat > "$unit_path" <<EOF
[Unit]
Description=agmsgd ($SKILL_DIR)

[Service]
ExecStart=$LAUNCHER
Restart=on-failure
RestartSec=30s
StartLimitIntervalSec=600
StartLimitBurst=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$unit_name"
}

_unregister_linux() {
  local unit_path unit_name
  unit_path="$(_systemd_unit_path)"
  unit_name="$(basename "$unit_path")"
  if [ -f "$unit_path" ]; then
    systemctl --user disable --now "$unit_name" 2>/dev/null || true
    rm -f "$unit_path"
    systemctl --user daemon-reload
  fi
}

_schtasks_name() { printf 'agmsgd-%s' "$(_unit_id)"; }

# NOT YET RUN ON WINDOWS in this environment -- written to T2's own
# win-test findings (LogonTrigger + RestartOnFailure via XML, since plain
# `/Create` flags do not set restart-on-failure) and shellchecked only.
_register_windows() {
  local node_path="$1" name xml
  name="$(_schtasks_name)"
  xml="$SKILL_DIR/run/${name}.xml"
  local native_launcher
  native_launcher="$(cygpath -w "$LAUNCHER" 2>/dev/null || printf '%s' "$LAUNCHER")"
  cat > "$xml" <<EOF
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
  </Triggers>
  <Actions>
    <Exec>
      <Command>bash.exe</Command>
      <Arguments>"$native_launcher"</Arguments>
    </Exec>
  </Actions>
  <Settings>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
</Task>
EOF
  schtasks /Create /TN "$name" /XML "$xml" /F
}

_unregister_windows() {
  local name
  name="$(_schtasks_name)"
  schtasks /Delete /TN "$name" /F 2>/dev/null || true
}

_register() {
  case "$(_os)" in
    darwin) _register_darwin "$1" ;;
    linux) _register_linux "$1" ;;
    windows) _register_windows "$1" ;;
    *) echo "agmsg daemon: unsupported OS for resident registration" >&2; return 1 ;;
  esac
}

_unregister() {
  case "$(_os)" in
    darwin) _unregister_darwin ;;
    linux) _unregister_linux ;;
    windows) _unregister_windows ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

# Confirms Node by actually running it (T2 #3), the same check
# agmsgd-launch.sh itself does -- enable/start both need this before
# recording node_path/node_version.
_resolve_node() {
  local candidate="${1:-node}" resolved
  resolved="$(command -v "$candidate" 2>/dev/null)" || return 1
  "$resolved" -e '
    const [maj, min] = process.versions.node.split(".").map(Number);
    if (maj < 22 || (maj === 22 && min < 13)) process.exit(1);
    require("node:sqlite");
  ' 2>/dev/null || return 1
  printf '%s' "$resolved"
}

_wait_for_ready() {
  local target_op_gen="$1" waited=0
  while [ "$waited" -lt 100 ]; do
    local state op_gen
    state="$(sqlite3 "$INSTALL_DB" "SELECT state FROM daemon_owner;" 2>/dev/null || true)"
    op_gen="$(sqlite3 "$INSTALL_DB" "SELECT op_gen FROM daemon_intent;" 2>/dev/null || true)"
    if [ "$state" = "ready" ] && [ "$op_gen" = "$target_op_gen" ]; then
      return 0
    fi
    waited=$((waited + 1))
    sleep 0.1
  done
  return 1
}

cmd_start() {
  _require_install_db
  # T3: "すでにdesired=onで、持ち主がreadyかつ実行者が生きているなら、何
  # も変えずに「もう動いている」で成功(op_genを上げない)". Reaching this
  # state at all REQUIRES desired to already have been 'on' (daemon_owner
  # only reaches 'ready' via the launcher, which refuses to start unless
  # desired is already 'on') -- so checking state=ready is sufficient on
  # its own; a separate desired=on check would only be re-confirming
  # something the state itself already implies.
  # This is an optimistic pre-check, not the authoritative one: it does
  # not itself verify the recorded executor is alive (that needs the pid +
  # boot-id comparison executor.mjs does, and duplicating that in bash is
  # not worth it here). If the record is stale (crashed, still says
  # 'ready'), this reports "already running" instead of starting a new
  # one -- a UX miss, not a safety one, because owner.mjs's own CAS inside
  # the launcher it would otherwise invoke is what actually protects
  # against two real owners; that CAS runs regardless of what this
  # pre-check decided.
  local state
  state="$(sqlite3 "$INSTALL_DB" "SELECT state FROM daemon_owner;")"
  if [ "$state" = "ready" ]; then
    echo "agmsg daemon start: already running"
    return 0
  fi

  local new_op_gen
  _with_op_lock "UPDATE daemon_intent SET desired = 'on', op_gen = op_gen + 1, set_by = 'start', set_at = strftime('%Y-%m-%dT%H:%M:%fZ','now');"
  new_op_gen="$(sqlite3 "$INSTALL_DB" "SELECT op_gen FROM daemon_intent;")"
  bash "$LAUNCHER" &
  disown 2>/dev/null || true
  if _wait_for_ready "$new_op_gen"; then
    echo "agmsg daemon start: running"
  else
    echo "agmsg daemon start: did not become ready in time -- check 'agmsg daemon status'" >&2
    return 1
  fi
}

# Best-effort courtesy nudge over the control socket -- NOT what confirms
# a stop; the caller's own polling of daemon_owner.state does that. A hard
# 5s ceiling: relying on the socket's own close/error events alone left
# this able to hang the whole command indefinitely if the daemon never
# answers (observed while testing: a daemon that had already started
# stepping aside for an unrelated reason at the same moment left this
# connection open with neither event firing).
_request_stop_over_socket() {
  local socket="$1"
  [ -n "$socket" ] || return 0
  node -e '
    const net = require("node:net");
    const s = net.createConnection(process.argv[1]);
    const done = () => { try { s.destroy(); } catch {} process.exit(0); };
    setTimeout(done, 5000);
    s.on("connect", () => {
      s.write(JSON.stringify({type:"hello",protocol:1,role:"control"}) + "\n");
      s.write(JSON.stringify({type:"stop"}) + "\n");
    });
    s.on("close", done);
    s.on("error", done);
  ' "$socket" 2>/dev/null || true
}

cmd_stop() {
  _require_install_db
  # T3: stop takes NO lock.
  local desired
  desired="$(sqlite3 "$INSTALL_DB" "SELECT desired FROM daemon_intent;" 2>/dev/null || true)"
  if [ "$desired" != "on" ]; then
    echo "agmsg daemon stop: already stopped"
    return 0
  fi
  sqlite3 "$INSTALL_DB" "UPDATE daemon_intent SET desired = 'off', op_gen = op_gen + 1, set_by = 'stop', set_at = strftime('%Y-%m-%dT%H:%M:%fZ','now');"
  local socket
  socket="$(sqlite3 "$INSTALL_DB" "SELECT socket FROM daemon_owner WHERE state = 'ready';" 2>/dev/null || true)"
  _request_stop_over_socket "$socket"
  local waited=0
  while [ "$waited" -lt 100 ]; do
    local state
    state="$(sqlite3 "$INSTALL_DB" "SELECT state FROM daemon_owner;" 2>/dev/null || true)"
    [ "$state" = "none" ] && { echo "agmsg daemon stop: stopped"; return 0; }
    waited=$((waited + 1))
    sleep 0.1
  done
  echo "agmsg daemon stop: requested, but it has not confirmed stopping yet -- check 'agmsg daemon status'" >&2
  return 1
}

cmd_status() {
  _require_install_db
  local node_path
  node_path="$(_resolve_node node 2>/dev/null || true)"
  if [ -n "$node_path" ]; then
    "$node_path" "$SCRIPT_DIR/daemon/status.mjs" "$SKILL_DIR"
    return $?
  fi
  # K14 fallback: no usable Node at all -- a minimal, honest read straight
  # from install.db rather than the fuller status.mjs decision text.
  local state desired
  state="$(sqlite3 "$INSTALL_DB" "SELECT state FROM daemon_owner;" 2>/dev/null || echo "unknown")"
  desired="$(sqlite3 "$INSTALL_DB" "SELECT desired FROM daemon_intent;" 2>/dev/null || echo "unknown")"
  echo "agmsg daemon status: state=$state intent=$desired (no usable Node -- a fuller check needs 'agmsg daemon enable')"
}

cmd_enable() {
  _require_install_db
  local node_path
  node_path="$(_resolve_node node)" || {
    echo "agmsg daemon enable: no usable Node found (need >= 22.13.0 with node:sqlite). Install one and try again." >&2
    return 1
  }
  local node_version
  node_version="$("$node_path" -e 'console.log(process.versions.node)')"
  _with_op_lock "
    UPDATE meta SET node_path = '$(printf '%s' "$node_path" | sed "s/'/''/g")', node_version = '$node_version';
    UPDATE daemon_intent SET desired = 'on';
  "
  _register "$node_path"
  cmd_start
}

cmd_disable() {
  _require_install_db
  _with_op_lock "UPDATE daemon_intent SET desired = 'off', op_gen = op_gen + 1, set_by = 'disable', set_at = strftime('%Y-%m-%dT%H:%M:%fZ','now');"
  _unregister
  local socket
  socket="$(sqlite3 "$INSTALL_DB" "SELECT socket FROM daemon_owner WHERE state = 'ready';" 2>/dev/null || true)"
  _request_stop_over_socket "$socket"
  echo "agmsg daemon disable: agmsgd turned off. Codex messages will go through the existing bridge again."
  echo "agmsg daemon disable: any Codex session started while agmsgd was in use needs to be restarted to get its bridge back."
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  *) _usage; exit 2 ;;
esac
