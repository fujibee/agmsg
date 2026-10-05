#!/usr/bin/env bats

# Claude Code native-channel delivery (2026-10-05, arch-8 §12.1): once
# agmsgd's own executor is verifiably ready, a claude-code seat must stop
# arming the generic Monitor watcher — the daemon delivers to its messaging
# socket directly instead, and a second, redundant receive path serves no
# purpose. This is the one property this file pins: daemon ready -> no
# Monitor directive; the usual directive is otherwise unaffected (every other
# session-start behavior is covered by test_session_start_terminal_line.bats
# and test_role_session.bats already).

load test_helper

setup() {
  setup_test_env
  export AGMSG_PLUGIN_DIRS=""
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  export PROJ="/tmp/agmsg-session-start-native-channel-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
}

teardown() { teardown_test_env; }

_run_session_start() {
  env AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/$1.sock" \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "{\"session_id\":\"$1\"}"
}

_mark_daemon_ready() {
  sqlite3 "$RUN_DIR/install.db" < "$SCRIPTS/daemon/schema.sql"
  local boot
  case "$(uname -s)" in
    Darwin) boot="$(sysctl -n kern.boottime | sed -n 's/.*sec = \([0-9]*\),.*/\1/p')" ;;
    Linux) boot="$(sed -n 's/^btime //p' /proc/stat)" ;;
    *) skip 'POSIX beta executor evidence' ;;
  esac
  sqlite3 "$RUN_DIR/install.db" "UPDATE daemon_intent SET desired='on';
    UPDATE daemon_owner SET state='ready', executor_pid=$$, executor_boot_id='$boot', executor_started_at=strftime('%Y-%m-%dT%H:%M:%fZ','now');"
}

@test "session-start: agmsgd ready -> no Monitor directive for a claude-code seat" {
  _mark_daemon_ready
  run _run_session_start "sid-daemon-ready"
  [ "$status" -eq 0 ]
  refute grep -q "AGMSG monitor mode" <<<"$output"
  refute grep -q "invoke the Monitor tool" <<<"$output"
  grep -qF "agmsgd is running and will deliver" <<<"$output"
}

@test "session-start: agmsgd not running -> the usual Monitor directive still fires" {
  run _run_session_start "sid-no-daemon"
  [ "$status" -eq 0 ]
  grep -qF "AGMSG monitor mode" <<<"$output"
}
