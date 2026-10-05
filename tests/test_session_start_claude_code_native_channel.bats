#!/usr/bin/env bats

# Claude Code native-channel delivery (2026-10-05, arch-8 §12.1): once
# agmsgd's own executor is verifiably ready, a claude-code seat must stop
# arming the generic Monitor watcher — the daemon delivers to its messaging
# socket directly instead, and a second, redundant receive path serves no
# purpose. But "ready" alone is not enough to skip Monitor (#1577 review):
# the daemon only ever addresses a seat whose role-session record actually
# carries a readable messaging_socket/claude_config_dir, so skipping Monitor
# for a seat that never got that record (never actas-claimed) would leave it
# with no delivery path at all. This file pins both halves of that gate.

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

@test "session-start: agmsgd ready AND an actas-claimed role-session record -> no Monitor directive" {
  _mark_daemon_ready
  bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code alice "sid-daemon-ready" >/dev/null
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

# The counterexample #1577 review required: daemon ready is NOT enough by
# itself. A seat that was only joined (never actas-claimed, so it has no
# role-session record at all, let alone a messaging_socket field) must keep
# its only delivery path -- Monitor -- rather than be silenced on the
# assumption the daemon can reach it.
@test "session-start: agmsgd ready but NO role-session record -> Monitor directive still fires" {
  _mark_daemon_ready
  run _run_session_start "sid-ready-no-record"
  [ "$status" -eq 0 ]
  grep -qF "AGMSG monitor mode" <<<"$output"
  refute grep -q "agmsgd is running and will deliver" <<<"$output"
}

# #1577 review: a session-start plug that updates every pair REGISTERED
# for the project, rather than only the pair this session actually holds the
# actas lock for, misdelivers one seat's socket into a different seat sharing
# the same project -- reproduced here with bob already claimed under his own
# session before alice's SessionStart ever runs. Alice's run must not touch
# bob's record at all.
@test "session-start: starting one seat never overwrites another seat's messaging record" {
  _mark_daemon_ready
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code bob "sid-bob" >/dev/null
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_set_messaging team bob /tmp/cc-socks/bob-original.sock /home/bob/.claude sid-bob

  bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code alice "sid-alice" >/dev/null
  run _run_session_start "sid-alice"
  [ "$status" -eq 0 ]

  [ "$(agmsg_role_session_get team bob messaging_socket)" = /tmp/cc-socks/bob-original.sock ]
  [ "$(agmsg_role_session_get team bob claude_config_dir)" = /home/bob/.claude ]
  [ "$(agmsg_role_session_uuid team bob)" = sid-bob ]
}
