#!/usr/bin/env bats

# A grok session under the shared `grok agent leader` runs its tool calls inside
# the leader, whose environment names the pane of the TUI that started it. The
# seat's own pane is found from GROK_SESSION_ID -> GROK_HOME/active_sessions.json
# -> the session's TUI -> that TUI's environment. Everything is faked: `ps` reads
# fixture files; no real grok, no real herdr.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_PLUGIN_DIRS=""
  unset AGMSG_SELF_NAME TMUX TMUX_PANE HERDR_PANE_ID HERDR_ENV GROK_SESSION_ID
  export FAKEBIN="$TEST_SKILL_DIR/fakebin" PSDIR="$TEST_SKILL_DIR/psfix"
  export GROK_HOME="$TEST_SKILL_DIR/grokhome"
  mkdir -p "$FAKEBIN" "$PSDIR"/{chain,env,lstart,etime} "$GROK_HOME"
  : > "$PSDIR/calls"
  export HERDR_SOCKET_PATH="$TEST_SKILL_DIR/herdr.sock"
  touch "$HERDR_SOCKET_PATH"
  cat > "$FAKEBIN/ps" <<'EOS'
#!/usr/bin/env bash
echo "ps $*" >> "$PSDIR/calls"
case "$*" in
  "-o ppid=,command= -p "*) f="$PSDIR/chain/$4"; [ -f "$f" ] || f="$PSDIR/chain/default"; [ -f "$f" ] && cat "$f" || exit 1 ;;
  "eww -p "*) f="$PSDIR/env/$3"; [ -f "$f" ] && cat "$f" || exit 1 ;;
  "-o etime= -p "*) f="$PSDIR/etime/$4"; [ -f "$f" ] && cat "$f" || exit 1 ;;
  "-o lstart= -p "*) f="$PSDIR/lstart/$4"; [ -f "$f" ] && cat "$f" || exit 1 ;;
  *) exit 1 ;;
esac
EOS
  chmod +x "$FAKEBIN/ps"
  export PATH="$FAKEBIN:$PATH"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
}
teardown() { teardown_test_env; }

_under_leader() {
  echo "5000 bash -c something" > "$PSDIR/chain/default"
  echo "1 /Users/x/.grok/bin/grok agent leader --no-exit-on-disconnect --relay-on-demand" > "$PSDIR/chain/5000"
}
_not_under_leader() {
  echo "5000 bash -c something" > "$PSDIR/chain/default"
  echo "1 /Users/x/.grok/bin/grok --resume abc" > "$PSDIR/chain/5000"
}
_session() {   # <session id> <tui pid> <tui pane>   (a process started 10 minutes ago)
  local start_us=$(( ($(date +%s) - 600) * 1000000 + 123456 ))
  printf '[{"session_id":"%s","pid":%s,"pid_start":%s,"cwd":"/w","opened_at":"x"}]\n' "$1" "$2" "$start_us" > "$GROK_HOME/active_sessions.json"
  printf '/x/grok GH_TOKEN=SENTINEL HERDR_ENV=1 HERDR_SOCKET_PATH=%s HERDR_PANE_ID=%s HOME=/h\n' "$HERDR_SOCKET_PATH" "$3" > "$PSDIR/env/$2"
  echo "Sun Nov  1 16:09:47 2026" > "$PSDIR/lstart/$2"
  echo "10:00" > "$PSDIR/etime/$2"
}
_tool_shell() {   # the leader's environment: the starter's pane
  export GROK_SESSION_ID="$1" HERDR_ENV=1 HERDR_PANE_ID='w5:p3'
}

@test "grok under the shared leader: the pane is the session's own TUI's, not the leader starter's" {
  _under_leader
  _session sess-b 14977 w1:p4G
  _tool_shell sess-b
  run agmsg_terminal_self_env
  [ "$status" -eq 0 ]
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:p4G"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  run agmsg_terminal_resolve_name ""
  [ "$output" = "$(printf 'herdr\t%s:w1:p4G' "$HERDR_SOCKET_PATH")" ]
}

@test "grok not under a leader keeps the environment, and a non-grok process pays nothing" {
  _not_under_leader
  _tool_shell sess-b
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w5:p3"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  unset GROK_SESSION_ID
  : > "$PSDIR/calls"
  run agmsg_terminal_self_env
  [ "$(grep -c '^ps -o ppid=' "$PSDIR/calls" || true)" -eq 0 ]
}

@test "grok under the leader whose session is not in active_sessions: unknown, nothing named" {
  _under_leader
  _session other 14977 w1:p4G
  _tool_shell sess-b
  run agmsg_terminal_self_env
  case "$output" in unknown:grok:shared_leader_pane_unproven:grok_session_not_in_active_sessions) ;; *) echo "$output"; return 1 ;; esac
  run agmsg_terminal_resolve_name ""
  [ "$status" -ne 0 ]
}

@test "a stale active_sessions entry whose pid was reused by a younger process is not trusted" {
  _under_leader
  _session sess-b 14977 w1:p4G
  echo "03:00" > "$PSDIR/etime/14977"    # started 3 minutes ago, not the recorded 10
  _tool_shell sess-b
  run agmsg_terminal_self_env
  case "$output" in unknown:*grok_session_process_is_not_the_recorded_one*) ;; *) echo "$output"; return 1 ;; esac
  run agmsg_terminal_resolve_name ""
  [ "$status" -ne 0 ]
  # The message names grok and the reason, not a Codex daemon.
  [[ "$output" == *"this grok session runs under a leader shared with another grok"* ]]
  [[ "$output" == *grok_session_process_is_not_the_recorded_one* ]]
  [[ "$output" != *Codex* ]]
}

@test "an age with days (dd-hh:mm:ss) is read, and a start time that cannot be read is unverifiable" {
  _under_leader
  local start_us=$(( ($(date +%s) - 283116) * 1000000 + 1420 ))
  printf '[{"session_id":"sess-b","pid":14977,"pid_start":%s,"cwd":"/w"}]\n' "$start_us" > "$GROK_HOME/active_sessions.json"
  printf '/x/grok HERDR_ENV=1 HERDR_SOCKET_PATH=%s HERDR_PANE_ID=w1:p4G\n' "$HERDR_SOCKET_PATH" > "$PSDIR/env/14977"
  echo "Sun Nov  1 16:09:47 2026" > "$PSDIR/lstart/14977"
  echo "3-06:38:36" > "$PSDIR/etime/14977"
  _tool_shell sess-b
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:p4G"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  rm -f "$SKILL_DIR"/run/grok-own-pane.*
  printf '[{"session_id":"sess-b","pid":14977,"cwd":"/w"}]\n' > "$GROK_HOME/active_sessions.json"
  run agmsg_terminal_self_env
  case "$output" in unknown:*grok_session_start_time_unverifiable*) ;; *) echo "$output"; return 1 ;; esac
}

@test "grok under the leader whose TUI environment has no pane: unknown" {
  _under_leader
  _session sess-b 14977 w1:p4G
  printf '/x/grok HOME=/h\n' > "$PSDIR/env/14977"
  _tool_shell sess-b
  run agmsg_terminal_self_env
  case "$output" in unknown:*grok_tui_environment_has_no_pane*) ;; *) echo "$output"; return 1 ;; esac
}

@test "grok under the leader without a session id in the shell: environment untouched (no grok to ask about)" {
  _under_leader
  export HERDR_ENV=1 HERDR_PANE_ID='w5:p3'
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w5:p3"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
}

@test "an ancestry that cannot be read is unknown, never the leader starter's pane" {
  _tool_shell sess-b
  rm -f "$PSDIR/chain/default"
  run agmsg_terminal_self_env
  case "$output" in unknown:*cannot_tell_whether_under_grok_leader*) ;; *) echo "$output"; return 1 ;; esac
}

@test "a proven pane is remembered, so later calls do not walk again" {
  _under_leader
  _session sess-b 14977 w1:p4G
  _tool_shell sess-b
  run agmsg_terminal_self_env
  : > "$PSDIR/calls"
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:p4G"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  [ "$(grep -c '^ps -o ppid=' "$PSDIR/calls" || true)" -eq 0 ]
}

@test "bash -x never prints the TUI's environment" {
  _under_leader
  _session sess-b 14977 w1:p4G
  printf '/x/grok GH_TOKEN=SENTINEL_ENV_SECRET HERDR_ENV=1 HERDR_SOCKET_PATH=%s HERDR_PANE_ID=w1:p4G AWS_SECRET=SENTINEL_ENV_SECRET2\n' "$HERDR_SOCKET_PATH" > "$PSDIR/env/14977"
  _tool_shell sess-b
  out="$TEST_SKILL_DIR/x.out"; err="$TEST_SKILL_DIR/x.err"
  export SKILL_DIR
  bash -x -c '. "$SKILL_DIR/scripts/lib/grok-own-pane.sh"; agmsg_grok_own_pane' >"$out" 2>"$err"
  grep -q 'HERDR_PANE_ID=w1:p4G' "$out"
  ! grep -rq SENTINEL "$out" "$err" "$SKILL_DIR/run"
}
