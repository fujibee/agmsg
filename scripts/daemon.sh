#!/usr/bin/env bash
# agmsgd's CLI ("agmsg daemon start|stop|status|enable|disable").
# Takes the subcommand as its first argument so the `agmsg` dispatcher
# wraps this file directly. User-facing instructions use `agmsg daemon ...`
# and give the installed dispatcher's absolute path when PATH is not set.
#
# No Node is required for `status` on the fast path: it reads
# install.db directly with sqlite3 first, and only shells out to Node
# (status.mjs) for the fuller decision text when Node is available and
# the record even suggests it's worth asking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DB="$SKILL_DIR/run/install.db"
LOCK_DB="$SKILL_DIR/run/install-op.lock.db"
LAUNCHER="$SCRIPT_DIR/daemon/agmsgd-launch.sh"
# shellcheck source=lib/daemon-state.sh
source "$SCRIPT_DIR/lib/daemon-state.sh"
# shellcheck source=lib/storage.sh
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck source=lib/daemon-seats.sh
source "$SCRIPT_DIR/lib/daemon-seats.sh"

_path_hint() {
  printf 'If agmsg is not found, use "%s/scripts/agmsg" daemon %s.\n' "$SKILL_DIR" "$1"
}

# Overridable so tests never register anything into the REAL resident
# manager (the real gui launchd domain, the real systemd --user, the real
# Task Scheduler) -- a test that killed a hung process outright, bypassing
# its own teardown, left exactly one real launchd unit behind on this
# machine. Tests point these at fake stand-ins; real registration is
# exercised only by hand and always torn down right after.
AGMSGD_LAUNCHCTL="${AGMSGD_LAUNCHCTL:-launchctl}"
AGMSGD_SYSTEMCTL="${AGMSGD_SYSTEMCTL:-systemctl}"
AGMSGD_SCHTASKS="${AGMSGD_SCHTASKS:-schtasks}"

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
# unqualified names -- see below) inside the operation lock. Optional
# remaining arguments name one resident-manager action that must share the
# same lock (enable/register or disable/unregister).
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
_install_generation() {
  local install_id manifest_path_sql manifest_id manifest_gen
  install_id="$(sqlite3 "$INSTALL_DB" "SELECT install_id FROM meta;" 2>/dev/null)" || return 1
  manifest_path_sql="$(printf '%s' "$SKILL_DIR/run/install-manifest.json" | sed "s/'/''/g")"
  IFS='|' read -r manifest_id manifest_gen < <(sqlite3 :memory: "SELECT json_extract(CAST(readfile('$manifest_path_sql') AS TEXT), '\$.install_id') || '|' || json_extract(CAST(readfile('$manifest_path_sql') AS TEXT), '\$.gen');" 2>/dev/null) || return 1
  [ -n "$install_id" ] && [ "$manifest_id" = "$install_id" ] && [ -n "$manifest_gen" ] || return 1
  printf '%s:%s' "$install_id" "$manifest_gen"
}

# Hold the SQLite installation lock across the database change and the
# resident-manager operation. The install generation is captured before
# acquisition and rechecked while the lock is held, so an upgrade between
# those points cannot register an obsolete launcher.
_with_op_lock() {
  local statements="$1" expected_generation current_generation ready applied lock_pid attach_path lock_dir
  local AGMSGD_LOCK_INSTALL_ID
  shift
  expected_generation="$(_install_generation)" || {
    echo "agmsg daemon: cannot read a complete install generation" >&2
    return 1
  }
  AGMSGD_LOCK_INSTALL_ID="${expected_generation%%:*}"
  lock_dir="$(mktemp -d "$SKILL_DIR/run/daemon-op-lock.XXXXXX")" || return 1
  mkfifo "$lock_dir/in" "$lock_dir/out"
  sqlite3 -batch "$LOCK_DB" < "$lock_dir/in" > "$lock_dir/out" 3>&- 4>&- &
  lock_pid=$!
  exec 8> "$lock_dir/in"
  exec 9< "$lock_dir/out"
  attach_path="$(printf '%s' "$INSTALL_DB" | sed "s/'/''/g")"
  printf '%s\n' '.bail on' "ATTACH DATABASE '$attach_path' AS installdb;" 'BEGIN EXCLUSIVE;' '.print LOCKED' >&8
  if ! IFS= read -r -t 10 ready <&9 || [ "$ready" != "LOCKED" ]; then
    printf 'ROLLBACK;\n.quit\n' >&8 2>/dev/null || true
    exec 8>&-
    exec 9<&-
    wait "$lock_pid" 2>/dev/null || true
    rm -f "$lock_dir/in" "$lock_dir/out"
    rmdir "$lock_dir"
    echo "agmsg daemon: could not acquire the install operation lock" >&2
    return 1
  fi
  local generation_row generation_marker manifest_sql
  manifest_sql="$(printf '%s' "$SKILL_DIR/run/install-manifest.json" | sed "s/'/''/g")"
  printf '%s\n' "SELECT CASE WHEN json_extract(CAST(readfile('$manifest_sql') AS TEXT), '\$.install_id') = (SELECT install_id FROM installdb.meta) THEN (SELECT install_id FROM installdb.meta) || ':' || json_extract(CAST(readfile('$manifest_sql') AS TEXT), '\$.gen') ELSE '' END;" '.print GENERATION_END' >&8
  IFS= read -r -t 10 generation_row <&9 || generation_row=""
  IFS= read -r -t 10 generation_marker <&9 || generation_marker=""
  current_generation="$generation_row"
  if [ "$generation_marker" != "GENERATION_END" ] || [ "$current_generation" != "$expected_generation" ]; then
    printf 'ROLLBACK;\n.quit\n' >&8
    exec 8>&-
    exec 9<&-
    wait "$lock_pid" 2>/dev/null || true
    rm -f "$lock_dir/in" "$lock_dir/out"
    rmdir "$lock_dir"
    echo "agmsg daemon: install generation changed while acquiring the operation lock; try again" >&2
    return 1
  fi
  if [ -n "$statements" ]; then
    printf '%s\n.print APPLIED\n' "$statements" >&8
    if ! IFS= read -r -t 10 applied <&9 || [ "$applied" != "APPLIED" ]; then
      printf 'ROLLBACK;\n.quit\n' >&8 2>/dev/null || true
      exec 8>&-
      exec 9<&-
      wait "$lock_pid" 2>/dev/null || true
      rm -f "$lock_dir/in" "$lock_dir/out"
      rmdir "$lock_dir"
      echo "agmsg daemon: install database update failed" >&2
      return 1
    fi
  fi
  local action_status=0
  if [ "$#" -gt 0 ]; then
    "$@" || action_status=$?
  fi
  if [ "$action_status" -eq 0 ]; then
    printf 'COMMIT;\n' >&8
  else
    printf 'ROLLBACK;\n' >&8
  fi
  printf '.quit\n' >&8
  exec 8>&-
  exec 9<&-
  wait "$lock_pid" || action_status=1
  rm -f "$lock_dir/in" "$lock_dir/out"
  rmdir "$lock_dir"
  return "$action_status"
}

# A short, stable id for this install's resident-manager unit name,
# derived from the install anchor (realpath + install_id). Beta uses two
# of the three (root path, install_id); the record DB's own path is
# already implied by being run/install.db under this same root, so it is
# not a third independent input here.
_unit_id() {
  local install_id="${AGMSGD_LOCK_INSTALL_ID:-}"
  if [ -z "$install_id" ]; then
    install_id="$(sqlite3 "$INSTALL_DB" "SELECT install_id FROM meta;" 2>/dev/null)"
  fi
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
# Resident registration. One function per OS; enable/
# disable call whichever applies. Only the darwin path has been run for
# real in this environment -- linux (systemd --user) and windows (Task
# Scheduler) use the same contract and are shellchecked, but need
# their own hands-on confirmation on those platforms, flagged in the PR
# rather than claimed here.
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
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardErrorPath</key><string>$SKILL_DIR/run/agmsgd.stderr.log</string>
</dict>
</plist>
EOF
  "$AGMSGD_LAUNCHCTL" bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || "$AGMSGD_LAUNCHCTL" load "$plist"
}

_unregister_darwin() {
  local label plist
  label="$(_launchd_label)"
  plist="$(_launchd_plist_path)"
  if [ -f "$plist" ]; then
    if ! "$AGMSGD_LAUNCHCTL" bootout "gui/$(id -u)/$label" 2>/dev/null && ! "$AGMSGD_LAUNCHCTL" unload "$plist" 2>/dev/null; then
      echo "agmsg daemon: could not unregister launchd service $label" >&2
      return 1
    fi
    rm -f "$plist"
  fi
}

_systemd_unit_path() { printf '%s/.config/systemd/user/agmsgd-%s.service' "$HOME" "$(_unit_id)"; }

# NOT YET RUN ON LINUX in this environment -- configured with
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
  "$AGMSGD_SYSTEMCTL" --user daemon-reload
  "$AGMSGD_SYSTEMCTL" --user enable "$unit_name"
}

_unregister_linux() {
  local unit_path unit_name
  unit_path="$(_systemd_unit_path)"
  unit_name="$(basename "$unit_path")"
  if [ -f "$unit_path" ]; then
    if ! "$AGMSGD_SYSTEMCTL" --user disable --now "$unit_name"; then
      echo "agmsg daemon: could not disable systemd user service $unit_name" >&2
      return 1
    fi
    rm -f "$unit_path"
    "$AGMSGD_SYSTEMCTL" --user daemon-reload
  fi
}

_schtasks_name() { printf 'agmsgd-%s' "$(_unit_id)"; }

_service_registered() {
  case "$(_os)" in
    darwin) [ -f "$(_launchd_plist_path)" ] ;;
    linux) [ -f "$(_systemd_unit_path)" ] ;;
    windows) [ -f "$SKILL_DIR/run/$(_schtasks_name).xml" ] ;;
    *) return 1 ;;
  esac
}

_start_registered_service() {
  case "$(_os)" in
    darwin) "$AGMSGD_LAUNCHCTL" kickstart "gui/$(id -u)/$(_launchd_label)" ;;
    linux) "$AGMSGD_SYSTEMCTL" --user start "$(basename "$(_systemd_unit_path)")" ;;
    windows) "$AGMSGD_SCHTASKS" /Run /TN "$(_schtasks_name)" ;;
    *) echo "agmsg daemon start: unsupported resident manager" >&2; return 1 ;;
  esac
}

_start_unregistered_launcher() {
  local stderr_log="${AGMSGD_TEST_LAUNCH_STDERR_LOG:-/dev/null}"
  bash "$LAUNCHER" </dev/null >/dev/null 2>"$stderr_log" 3>&- 4>&- &
  disown 2>/dev/null || true
}

# NOT YET RUN ON WINDOWS in this environment -- written to the Windows
# Task Scheduler contract (LogonTrigger + RestartOnFailure via XML, since plain
# `/Create` flags do not set restart-on-failure) and shellchecked only.
_register_windows() {
  local node_path="$1" name xml
  name="$(_schtasks_name)"
  xml="$SKILL_DIR/run/${name}.xml"
  local native_launcher
  native_launcher="$(cygpath -w "$LAUNCHER" 2>/dev/null || printf '%s' "$LAUNCHER")"
  local xml_utf8="$xml.utf8"
  cat > "$xml_utf8" <<EOF
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
  { printf '\xff\xfe'; iconv -f UTF-8 -t UTF-16LE "$xml_utf8"; } > "$xml"
  rm -f "$xml_utf8"
  "$AGMSGD_SCHTASKS" /Create /TN "$name" /XML "$xml" /F
}

_unregister_windows() {
  local name xml
  name="$(_schtasks_name)"
  xml="$SKILL_DIR/run/$name.xml"
  if [ ! -f "$xml" ]; then
    return 0
  fi
  if ! "$AGMSGD_SCHTASKS" /Delete /TN "$name" /F; then
    echo "agmsg daemon: could not delete scheduled task $name" >&2
    return 1
  fi
  rm -f "$xml"
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

# Confirms Node by actually running it, the same check
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
  local state
  state="$(sqlite3 "$INSTALL_DB" "SELECT state FROM daemon_owner;")"
  if [ "$state" = "ready" ] && node "$SCRIPT_DIR/daemon/status.mjs" "$SKILL_DIR" >/dev/null 2>&1; then
    echo "agmsg daemon start: already running"
    agmsg_daemon_seat_report start
    _path_hint status
    return 0
  fi

  local new_op_gen
  _with_op_lock "UPDATE daemon_intent SET desired = 'on', op_gen = op_gen + 1, set_by = 'start', set_at = strftime('%Y-%m-%dT%H:%M:%fZ','now');"
  new_op_gen="$(sqlite3 "$INSTALL_DB" "SELECT op_gen FROM daemon_intent;")"
  if _service_registered; then
    if ! _start_registered_service; then
      echo "agmsg daemon start: the registered service manager could not start agmsgd" >&2
      return 1
    fi
  else
    _start_unregistered_launcher
  fi
  if _wait_for_ready "$new_op_gen"; then
    echo "agmsg daemon start: running"
    agmsg_daemon_seat_report start
    _path_hint status
  else
    echo "agmsg daemon start: did not become ready in time -- check 'agmsg daemon status'" >&2
    agmsg_daemon_warn_if_stopped always
    _path_hint status >&2
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
  # Stop takes no operation lock.
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
  agmsg_daemon_read_state
  local health_rc=0
  if [ "${AGMSGD_DESIRED:-unknown}" = on ] && [ "${AGMSGD_HEALTH:-unknown}" != ready ]; then
    agmsg_daemon_recovery_text
    health_rc=1
  elif [ "${AGMSGD_HEALTH:-unknown}" = unknown ]; then
    echo 'agmsg daemon status: install record could not be read; health is unknown'
    health_rc=1
  fi
  local node_path
  node_path="$(_resolve_node node 2>/dev/null || true)"
  if [ -n "$node_path" ]; then
    local status_rc=0
    "$node_path" "$SCRIPT_DIR/daemon/status.mjs" "$SKILL_DIR" || status_rc=$?
    agmsg_daemon_seat_report status
    [ "$health_rc" -eq 0 ] || return 1
    return "$status_rc"
  fi
  # K14 fallback: no usable Node at all -- a minimal, honest read straight
  # from install.db rather than the fuller status.mjs decision text.
  local state desired
  state="$(sqlite3 "$INSTALL_DB" "SELECT state FROM daemon_owner;" 2>/dev/null || echo "unknown")"
  desired="$(sqlite3 "$INSTALL_DB" "SELECT desired FROM daemon_intent;" 2>/dev/null || echo "unknown")"
  echo "agmsg daemon status: state=$state intent=$desired (no usable Node -- a fuller check needs 'agmsg daemon enable')"
  agmsg_daemon_seat_report status
  _path_hint enable
  return "$health_rc"
}

cmd_enable() {
  _require_install_db
  local node_path
  node_path="$(_resolve_node node)" || {
    echo "agmsg daemon enable: no usable Node found (need >= 22.13.0 with node:sqlite). Install one and try again." >&2
    echo 'Install Node from https://nodejs.org/en/download, then run agmsg daemon enable.' >&2
    _path_hint enable >&2
    return 1
  }
  local node_version
  node_version="$("$node_path" -e 'console.log(process.versions.node)')"
  _with_op_lock "
    UPDATE meta SET node_path = '$(printf '%s' "$node_path" | sed "s/'/''/g")', node_version = '$node_version';
    UPDATE daemon_intent SET desired = 'on';
  " _register "$node_path" || {
    if ! _with_op_lock "" _unregister; then
      echo "agmsg daemon enable: could not clean up the partially registered service" >&2
    fi
    return 1
  }
  cmd_start
}

cmd_disable() {
  _require_install_db
  _with_op_lock "UPDATE daemon_intent SET desired = 'off', op_gen = op_gen + 1, set_by = 'disable', set_at = strftime('%Y-%m-%dT%H:%M:%fZ','now');" _unregister
  local socket
  socket="$(sqlite3 "$INSTALL_DB" "SELECT socket FROM daemon_owner WHERE state = 'ready';" 2>/dev/null || true)"
  _request_stop_over_socket "$socket"
  local waited=0 state
  while [ "$waited" -lt 100 ]; do
    state="$(sqlite3 "$INSTALL_DB" "SELECT state FROM daemon_owner;" 2>/dev/null || true)"
    [ "$state" = "none" ] && break
    waited=$((waited + 1))
    sleep 0.1
  done
  if [ "$state" != "none" ]; then
    echo "agmsg daemon disable: service was unregistered but agmsgd has not confirmed stopping -- check 'agmsg daemon status'" >&2
    return 1
  fi
  echo 'agmsg daemon disable: agmsgd turned off. Existing bridges continue to deliver notices; new Codex launches get a bridge.'
  echo 'Codex sessions without a bridge must be restarted. Until then they receive no new notices; unread messages are preserved. Restart with codex resume, then enter $agmsg actas <name> in that Codex session.'
  echo 'Notices already accepted by the Codex queue are not cancelled and may appear once more.'
  agmsg_daemon_seat_report disable
  _path_hint disable
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  *) _usage; exit 2 ;;
esac
