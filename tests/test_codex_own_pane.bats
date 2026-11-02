#!/usr/bin/env bats

# #1736: a Codex seat under the shared app-server daemon must not take its pane
# from the environment (the daemon starter's pane). It is found from its thread:
# CODEX_THREAD_ID -> the TUI that holds that thread -> that TUI's own environment.
#
# Everything is faked: `ps` and `lsof` read fixture files, the thread table is a
# throwaway state_5.sqlite under a throwaway CODEX_HOME. No real Codex, no real
# herdr, no shared daemon is touched.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_PLUGIN_DIRS=""
  unset AGMSG_SELF_NAME TMUX TMUX_PANE HERDR_PANE_ID HERDR_ENV CODEX_THREAD_ID
  export FAKEBIN="$TEST_SKILL_DIR/fakebin"
  export PSDIR="$TEST_SKILL_DIR/psfix"
  export CODEX_HOME="$TEST_SKILL_DIR/codex-home"
  mkdir -p "$FAKEBIN" "$PSDIR"/{chain,env,lstart,cwd} "$CODEX_HOME"
  : > "$PSDIR/calls"
  : > "$PSDIR/list"
  export HERDR_SOCKET_PATH="$TEST_SKILL_DIR/herdr.sock"
  touch "$HERDR_SOCKET_PATH"

  cat > "$FAKEBIN/ps" <<'EOF'
#!/usr/bin/env bash
# Fixture-driven ps: only the four shapes agmsg uses.
echo "ps $*" >> "$PSDIR/calls"
case "$*" in
  "-o ppid=,command= -p "*)
    [ -f "$PSDIR/fail_chain" ] && exit 1
    f="$PSDIR/chain/$4"; [ -f "$f" ] || f="$PSDIR/chain/default"
    [ -f "$f" ] && cat "$f" || exit 1 ;;
  "-axo pid=,ppid=,etime=,command=") echo "LIST" >> "$PSDIR/calls"; cat "$PSDIR/list" ;;
  "eww -p "*) f="$PSDIR/env/$3"; [ -f "$f" ] && cat "$f" || exit 1 ;;
  "-o ppid= -p "*) awk -v want="$4" '$1 == want { print $2 }' "$PSDIR/list" ;;
  "-o lstart= -p "*) f="$PSDIR/lstart/$4"; [ -f "$f" ] && cat "$f" || exit 1 ;;
  *) exit 1 ;;
esac
EOF
  cat > "$FAKEBIN/pgrep" <<'EOF'
#!/usr/bin/env bash
# pgrep -f <pattern>: pids of list lines whose command matches; pgrep -P <ppid>: children
echo "pgrep $*" >> "$PSDIR/calls"
[ -f "$PSDIR/pgrep_fail" ] && exit "$(cat "$PSDIR/pgrep_fail")"
if [ "$1" = -P ]; then awk -v pp="$2" '$2 == pp { print $1 }' "$PSDIR/list"
else awk -v pat="$2" '{ c = $4; for (i = 5; i <= NF; i++) c = c " " $i; if (index(c, pat)) print $1 }' "$PSDIR/list"; fi
EOF
  cat > "$FAKEBIN/lsof" <<'EOF'
#!/usr/bin/env bash
# lsof -a -p <pid> -d cwd -Fn
f="$PSDIR/cwd/$3"; [ -f "$f" ] || exit 1
printf 'p%s\nn%s\n' "$3" "$(cat "$f")"
EOF
  chmod +x "$FAKEBIN/ps" "$FAKEBIN/lsof" "$FAKEBIN/pgrep"
  export PATH="$FAKEBIN:$PATH"

  sqlite3 "$CODEX_HOME/state_5.sqlite" "create table threads(id text primary key, cwd text, created_at integer);"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
}

teardown() { teardown_test_env; }

# --- fixture helpers -------------------------------------------------------
_under_daemon() {   # any process's ancestry: shell -> managed daemon
  echo "5000 bash -c something" > "$PSDIR/chain/default"
  echo "1 /x/codex app-server --listen unix:// --managed-daemon" > "$PSDIR/chain/5000"
}
_not_under_daemon() {
  echo "5000 bash -c something" > "$PSDIR/chain/default"
  echo "1 /sbin/launchd" > "$PSDIR/chain/5000"
}
_thread() {   # <id> <cwd> <age-seconds>
  sqlite3 "$CODEX_HOME/state_5.sqlite" "insert into threads values('$1','$2',$(( $(date +%s) - $3 )));"
}
_tui() {   # <pid> <etime> <cwd> <pane> [argv...]
  local pid="$1" etime="$2" cwd="$3" pane="$4"; shift 4
  printf '%s 1 %s /v/bin/codex%s\n' "$pid" "$etime" "${*:+ $*}" >> "$PSDIR/list"
  printf '%s\n' "$cwd" > "$PSDIR/cwd/$pid"
  printf '/v/bin/codex HERDR_ENV=1 HERDR_SOCKET_PATH=%s HERDR_PANE_ID=%s HOME=/h\n' "$HERDR_SOCKET_PATH" "$pane" > "$PSDIR/env/$pid"
  echo "Sun Nov  1 16:09:47 2026" > "$PSDIR/lstart/$pid"
}
_seat() {   # the tool shell the seat runs: the daemon's env, the starter's pane
  export CODEX_THREAD_ID="$1" HERDR_ENV=1 HERDR_PANE_ID='w1:p17'
}

@test "daemon seat: the pane comes from the TUI that started with its thread, not the environment" {
  _under_daemon
  _thread t-aaa /work/a 600
  _thread t-bbb /work/a 300
  _tui 91001 10:00 /work/a w1:pC
  _tui 91002 05:00 /work/a w1:pN
  _seat t-bbb
  run agmsg_terminal_self_env
  [ "$status" -eq 0 ]
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:pN"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  _seat t-aaa
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:pC"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
}

@test "daemon seat: resolve_name answers the same pane" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC
  _seat t-aaa
  run agmsg_terminal_resolve_name ""
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\t%s:w1:pC' "$HERDR_SOCKET_PATH")" ]
}

@test "a resumed thread is found by its codex resume argv, whatever its start time" {
  _under_daemon
  _thread t-old /work/a 90000
  # the npm launcher and the TUI it starts both carry `codex resume <id>`
  printf '92000 1 03:00 node /n/bin/codex resume t-old\n92001 92000 03:00 /v/bin/codex resume t-old\n' >> "$PSDIR/list"
  printf '/v/bin/codex HERDR_ENV=1 HERDR_SOCKET_PATH=%s HERDR_PANE_ID=w1:p9\n' "$HERDR_SOCKET_PATH" > "$PSDIR/env/92001"
  echo "Sun Nov  1 16:10:00 2026" > "$PSDIR/lstart/92001"
  _tui 91001 10:00 /work/a w1:pC
  _seat t-old
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:p9"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
}

@test "two TUIs started in the same second in one cwd: unknown, nothing is named" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC
  _tui 91002 10:01 /work/a w1:pN
  _seat t-aaa
  run agmsg_terminal_self_env
  [ "$status" -eq 0 ]
  case "$output" in unknown:codex:shared_daemon_pane_unproven:several_codex_tuis_may_hold_this_thread) ;; *) echo "$output"; return 1 ;; esac
  run agmsg_terminal_resolve_name ""
  [ "$status" -eq 1 ]
  case "$output" in *"could not be proven"*"several_codex_tuis_may_hold_this_thread"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "no TUI started near the thread's creation (a thread made later in the same TUI): unknown" {
  _under_daemon
  _thread t-late /work/a 100
  _tui 91001 10:00 /work/a w1:pC
  _seat t-late
  run agmsg_terminal_self_env
  [ "$output" = "unknown:codex:shared_daemon_pane_unproven:no_codex_tui_holds_this_thread" ]
}

@test "a TUI in another cwd is not a match even at the same second" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/other w1:pC
  _seat t-aaa
  run agmsg_terminal_self_env
  [ "$output" = "unknown:codex:shared_daemon_pane_unproven:no_codex_tui_holds_this_thread" ]
}

@test "a thread missing from Codex's table is unknown, not guessed" {
  _under_daemon
  _tui 91001 10:00 /work/a w1:pC
  _seat t-nowhere
  run agmsg_terminal_self_env
  [ "$output" = "unknown:codex:shared_daemon_pane_unproven:thread_not_in_codex_state_db" ]
}

@test "outside the shared daemon the environment is used exactly as before" {
  _not_under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC
  _seat t-aaa
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:p17"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  ! grep -q '^LIST$' "$PSDIR/calls"
}

@test "not a Codex seat (no CODEX_THREAD_ID): no ps at all" {
  _under_daemon
  export HERDR_ENV=1 HERDR_PANE_ID='w1:p3'
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:p3"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  [ ! -s "$PSDIR/calls" ]
}

@test "a settled pane is remembered: the process list is read once per thread" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC
  _seat t-aaa
  agmsg_terminal_self_env >/dev/null
  agmsg_terminal_self_env >/dev/null
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:pC"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  [ "$(grep -c '^LIST$' "$PSDIR/calls")" -eq 1 ]
  # and a repeat costs one ps (the TUI pid still has the recorded start time)
  # and one pgrep (is there another `codex resume <thread>`?), nothing else
  local before after pbefore pafter
  before="$(grep -c '^ps ' "$PSDIR/calls")"; pbefore="$(grep -c '^pgrep ' "$PSDIR/calls")"
  agmsg_terminal_self_env >/dev/null
  after="$(grep -c '^ps ' "$PSDIR/calls")"; pafter="$(grep -c '^pgrep ' "$PSDIR/calls")"
  [ "$((after - before))" -eq 1 ]
  [ "$((pafter - pbefore))" -eq 1 ]
}

@test "a remembered pane is dropped when its TUI pid now has a different start time" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC
  _seat t-aaa
  agmsg_terminal_self_env >/dev/null
  echo "Sun Nov  1 17:00:00 2026" > "$PSDIR/lstart/91001"   # pid reused
  echo "777 1 00:05 /bin/sleep 5" > "$PSDIR/list"            # and the TUI is gone
  run agmsg_terminal_self_env
  [ "$output" = "unknown:codex:shared_daemon_pane_unproven:no_codex_process_listed" ]
}

@test "an unknown verdict is remembered only briefly, so a later start can settle it" {
  _under_daemon
  _thread t-aaa /work/a 600
  _seat t-aaa
  run agmsg_terminal_self_env
  case "$output" in unknown:*) ;; *) echo "$output"; return 1 ;; esac
  _tui 91001 10:00 /work/a w1:pC
  AGMSG_CODEX_UNKNOWN_TTL=0 run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:pC"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
}

@test "tmux: the TUI's TMUX and TMUX_PANE are used the same way" {
  _under_daemon
  _thread t-aaa /work/a 600
  printf '91001 1 10:00 /v/bin/codex\n' >> "$PSDIR/list"
  echo /work/a > "$PSDIR/cwd/91001"
  printf '/v/bin/codex TMUX=/tmp/tmux-1/default,4321,0 TMUX_PANE=%%7 HOME=/h\n' > "$PSDIR/env/91001"
  echo "Sun Nov  1 16:09:47 2026" > "$PSDIR/lstart/91001"
  export CODEX_THREAD_ID=t-aaa TMUX=/tmp/tmux-1/default,4321,0 TMUX_PANE='%1'
  run agmsg_terminal_self_env
  [ "$output" = "$(printf 'tmux\t/tmp/tmux-1/default:%%7\tpid=4321')" ]
}

# --- review fixes -------------------------------------------------------------

@test "bash -x never prints the TUI's environment or other processes' command lines" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC
  # sentinels: a secret in the TUI's environment and one in another process's argv
  printf '/v/bin/codex GH_TOKEN=SENTINEL_ENV_SECRET HERDR_ENV=1 HERDR_SOCKET_PATH=%s HERDR_PANE_ID=w1:pC AWS_SECRET=SENTINEL_ENV_SECRET2 TMUX_PANE=%%3\n' "$HERDR_SOCKET_PATH" > "$PSDIR/env/91001"
  printf '93000 1 01:00 /bin/tool --token=SENTINEL_ARGV_SECRET\n' >> "$PSDIR/list"
  echo "5000 bash --password=SENTINEL_CHAIN_SECRET" > "$PSDIR/chain/default"
  export CODEX_THREAD_ID=t-aaa HERDR_ENV=1 HERDR_PANE_ID=w1:p17
  local out="$TEST_SKILL_DIR/xtrace.out" err="$TEST_SKILL_DIR/xtrace.err"
  bash -x -c '. "$SKILL_DIR/scripts/lib/codex-own-pane.sh"; agmsg_codex_own_pane' >"$out" 2>"$err"
  grep -q 'HERDR_PANE_ID=w1:pC' "$out"
  ! grep -rq SENTINEL "$out" "$err" "$SKILL_DIR/run"
}

@test "a failed ancestry check is unknown, never the daemon starter's pane" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC
  : > "$PSDIR/fail_chain"
  _seat t-aaa
  run agmsg_terminal_self_env
  [ "$output" = "unknown:codex:shared_daemon_pane_unproven:cannot_tell_whether_under_shared_daemon" ]
  run agmsg_terminal_resolve_name ""
  [ "$status" -eq 1 ]
  # and it is not remembered as trusted: once ps works, the real answer comes
  rm -f "$PSDIR/fail_chain"
  AGMSG_CODEX_UNKNOWN_TTL=0 run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:pC"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
}

@test "an ancestry walk cut off at 16 hops is unknown, not trusted" {
  local i
  for i in $(seq 1 40); do echo "$((i + 1)) bash" > "$PSDIR/chain/$i"; done
  echo "2 bash" > "$PSDIR/chain/default"
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC
  _seat t-aaa
  run agmsg_terminal_self_env
  [ "$output" = "unknown:codex:shared_daemon_pane_unproven:cannot_tell_whether_under_shared_daemon" ]
}

@test "a thread that a resume argv and a start-time match place on two screens is unknown" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC                       # started with the thread
  printf '92001 1 40:00 /v/bin/codex resume t-aaa\n' >> "$PSDIR/list"   # and another screen resumed it
  printf '/v/bin/codex HERDR_ENV=1 HERDR_SOCKET_PATH=%s HERDR_PANE_ID=w1:p9\n' "$HERDR_SOCKET_PATH" > "$PSDIR/env/92001"
  _seat t-aaa
  run agmsg_terminal_self_env
  [ "$output" = "unknown:codex:shared_daemon_pane_unproven:several_codex_tuis_may_hold_this_thread" ]
}

@test "a proven pane is only trusted for the pane TTL, then the scan is repeated" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC
  _seat t-aaa
  agmsg_terminal_self_env >/dev/null
  AGMSG_CODEX_PANE_TTL=0 agmsg_terminal_self_env >/dev/null
  [ "$(grep -c '^LIST$' "$PSDIR/calls")" -eq 2 ]
}

@test "a remembered pane is dropped when another screen starts resuming the same thread" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC                      # P1: started with A, cached
  _seat t-aaa
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:pC"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  # P1 does /clear (still alive, argv unchanged); P2 resumes A
  printf '92001 1 01:00 /v/bin/codex resume t-aaa\n' >> "$PSDIR/list"
  printf '/v/bin/codex HERDR_ENV=1 HERDR_SOCKET_PATH=%s HERDR_PANE_ID=w1:p9\n' "$HERDR_SOCKET_PATH" > "$PSDIR/env/92001"
  echo "Sun Nov  1 16:20:00 2026" > "$PSDIR/lstart/92001"
  run agmsg_terminal_self_env
  [ "$output" = "unknown:codex:shared_daemon_pane_unproven:several_codex_tuis_may_hold_this_thread" ]
}

@test "a resumed seat's own launcher and TUI do not invalidate its remembered pane" {
  _under_daemon
  _thread t-old /work/a 90000
  printf '92000 1 03:00 node /n/bin/codex resume t-old\n92001 92000 03:00 /v/bin/codex resume t-old\n' >> "$PSDIR/list"
  printf '/v/bin/codex HERDR_ENV=1 HERDR_SOCKET_PATH=%s HERDR_PANE_ID=w1:p9\n' "$HERDR_SOCKET_PATH" > "$PSDIR/env/92001"
  echo "Sun Nov  1 16:10:00 2026" > "$PSDIR/lstart/92001"
  _seat t-old
  agmsg_terminal_self_env >/dev/null
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:p9"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  [ "$(grep -c '^LIST$' "$PSDIR/calls")" -eq 1 ]
}

@test "pgrep exiting 2 on a cache hit is unknown: neither the remembered pane nor 'none'" {
  _under_daemon
  _thread t-aaa /work/a 600
  _tui 91001 10:00 /work/a w1:pC
  _seat t-aaa
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:pC"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  # exit 1 is the ordinary "no match": the remembered pane stands, no rescan
  echo 1 > "$PSDIR/pgrep_fail"
  run agmsg_terminal_self_env
  case "$output" in "herdr"$'\t'"$HERDR_SOCKET_PATH:w1:pC"$'\t'*) ;; *) echo "$output"; return 1 ;; esac
  [ "$(grep -c '^LIST$' "$PSDIR/calls")" -eq 1 ]
  # any other exit is not an answer
  echo 2 > "$PSDIR/pgrep_fail"
  run agmsg_terminal_self_env
  [ "$output" = "unknown:codex:shared_daemon_pane_unproven:cannot_check_for_another_resume_of_this_thread" ]
}
