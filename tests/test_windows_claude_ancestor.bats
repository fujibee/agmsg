#!/usr/bin/env bats

# Windows Claude owner resolution. Most cases use deterministic process-table
# stubs so boundary, cycle and failure behavior runs on every platform. The
# final lifecycle cases use real WINPIDs when the suite runs under Git Bash.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  export PROJ="/tmp/agmsg-windows-claude-owner"
  mkdir -p "$RUN_DIR"
  AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/compat.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/resolve-project.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/instance-id.sh"
  OWNER_MSYS_PID=""
  WATCH_PID=""
  EXTRA_PIDS=""
}

teardown() {
  if [ -n "${WATCH_PID:-}" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  if [ -n "${OWNER_MSYS_PID:-}" ]; then
    kill "$OWNER_MSYS_PID" 2>/dev/null || true
    wait "$OWNER_MSYS_PID" 2>/dev/null || true
  fi
  local p
  for p in ${EXTRA_PIDS:-}; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  teardown_test_env
}

force_platform() { _agmsg_platform="$1"; }

start_native_claude_owner() {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "requires Git Bash on Windows" ;; esac
  cp /usr/bin/sleep.exe "$TEST_SKILL_DIR/claude.exe"
  "$TEST_SKILL_DIR/claude.exe" 180 & OWNER_MSYS_PID=$!
  OWNER_WINPID="$(compat_msys_pid_to_winpid "$OWNER_MSYS_PID")"
  case "$OWNER_WINPID" in ''|*[!0-9]*) false ;; esac
  OWNER_CREATION="$(agmsg_resolved_pid_creation_token "$OWNER_WINPID" claude-code 2>/dev/null || true)"
  if [ -z "$OWNER_CREATION" ]; then
    kill "$OWNER_MSYS_PID" 2>/dev/null || true
    wait "$OWNER_MSYS_PID" 2>/dev/null || true
    OWNER_MSYS_PID=""
    skip "Win32_Process CreationDate query is unavailable"
  fi
}

start_watch_standin() {
  bash -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' "$SCRIPTS/watch.sh" &
  STANDIN_PID=$!
  EXTRA_PIDS="${EXTRA_PIDS:+$EXTRA_PIDS }$STANDIN_PID"
}

track_pid() { EXTRA_PIDS="${EXTRA_PIDS:+$EXTRA_PIDS }$1"; }

wait_for_pid_exit() {
  local pid="$1" i
  for i in $(seq 1 80); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

@test "agent pid: POSIX PPID walk is unchanged" {
  force_platform linux
  compat_get_ppid() { case "$1" in "$$") echo 10 ;; 10) echo 20 ;; *) echo 1 ;; esac; }
  agmsg_pid_is_agent() { [ "$1" = 20 ] && [ "$2" = claude-code ]; }
  run agmsg_agent_pid claude-code
  [ "$status" -eq 0 ]
  [ "$output" = 20 ]
}

@test "agent pid: Windows finds Claude inside the MSYS chain and returns WINPID" {
  force_platform msys
  compat_get_ppid() { case "$1" in "$$") echo 10 ;; 10) echo 20 ;; *) echo 1 ;; esac; }
  agmsg_pid_is_agent() { [ "$1" = 20 ]; }
  compat_msys_pid_to_winpid() { [ "$1" = 20 ] && echo 2020; }
  agmsg_native_pid_is_agent() { [ "$1" = 2020 ] && [ "$2" = claude-code ]; }
  run agmsg_agent_pid claude-code
  [ "$status" -eq 0 ]
  [ "$output" = 2020 ]
}

@test "agent pid: Windows crosses the boundary and finds a native Claude ancestor" {
  force_platform msys
  compat_get_ppid() { case "$1" in "$$") echo 10 ;; 10) echo 1 ;; esac; }
  agmsg_pid_is_agent() { return 1; }
  compat_msys_pid_to_winpid() { [ "$1" = 10 ] && echo 1010; }
  compat_pid_state_native() { echo alive; }
  compat_native_process_record() { case "$1" in 1010) printf '2000\x1f101\x1fbash.exe\x1fC:/Git/bash.exe\x1fC:/Git/bash.exe' ;; 2000) printf '3000\x1f102\x1fbash.exe\x1fC:/Git/bash.exe\x1fC:/Git/bash.exe' ;; 3000) printf '4000\x1f103\x1fclaude.exe\x1fC:/tools/claude.exe\x1fC:/tools/claude.exe' ;; esac; }
  run agmsg_agent_pid claude-code
  [ "$status" -eq 0 ]
  [ "$output" = 3000 ]
}

@test "agent pid: multiple native bash relays do not hide Claude" {
  force_platform msys
  compat_get_ppid() { case "$1" in "$$") echo 10 ;; 10) echo 1 ;; esac; }
  agmsg_pid_is_agent() { return 1; }
  compat_msys_pid_to_winpid() { echo 1000; }
  compat_pid_state_native() { echo alive; }
  compat_native_process_record() { case "$1" in 1000) printf '2000\x1f101\x1fbash.exe\x1fC:/Git/bash.exe\x1fC:/Git/bash.exe' ;; 2000) printf '3000\x1f102\x1fbash.exe\x1fC:/Git/bash.exe\x1fC:/Git/bash.exe' ;; 3000) printf '4000\x1f103\x1fbash.exe\x1fC:/Git/bash.exe\x1fC:/Git/bash.exe' ;; 4000) printf '5000\x1f104\x1fbash.exe\x1fC:/Git/bash.exe\x1fC:/Git/bash.exe' ;; 5000) printf '6000\x1f105\x1fclaude.exe\x1fC:/Claude/claude.exe\x1fC:/Claude/claude.exe' ;; esac; }
  [ "$(agmsg_agent_pid claude-code)" = 5000 ]
}

@test "agent pid: native command line that is not Claude is rejected" {
  force_platform msys
  compat_get_ppid() { case "$1" in "$$") echo 10 ;; 10) echo 1 ;; esac; }
  agmsg_pid_is_agent() { return 1; }
  compat_msys_pid_to_winpid() { echo 1000; }
  compat_pid_state_native() { echo alive; }
  compat_native_process_record() { case "$1" in 1000) printf '2000\x1f101\x1fnotepad.exe\x1fC:/Windows/notepad.exe\x1fC:/Windows/notepad.exe notes-about-claude.txt' ;; 2000) printf '1\x1f102\x1fnotepad.exe\x1fC:/Windows/notepad.exe\x1fC:/Windows/notepad.exe' ;; esac; }
  run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "owner state: CIM failure is unknown and cannot authorize teardown" {
  force_platform msys
  compat_pid_state_native() { echo unknown; }
  run agmsg_instance_owner_state sess.4242 claude-code
  [ "$status" -eq 0 ]
  [ "$output" = unknown ]
}

@test "agent pid: native cycle and hop limit terminate" {
  force_platform msys
  compat_get_ppid() { case "$1" in "$$") echo 10 ;; 10) echo 1 ;; esac; }
  agmsg_pid_is_agent() { return 1; }
  compat_msys_pid_to_winpid() { echo 1000; }
  agmsg_native_pid_inspect() { case "$1" in 1000) printf 'no-match\t2000' ;; 2000) printf 'no-match\t1000' ;; esac; }
  run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]

  agmsg_native_pid_inspect() { printf 'no-match\t%s' "$(($1 + 1))"; }
  AGMSG_AGENT_PID_MAX_HOPS=3 run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]
}

@test "instance id: native Claude WINPID produces a composite id" {
  agmsg_agent_pid() { echo 4242; }
  [ "$(agmsg_instance_id uuid claude-code)" = uuid.4242 ]
}

@test "project marker: resolved Windows WINPID is validated in native domain" {
  force_platform msys
  agmsg_native_pid_is_agent() { [ "$1" = 4242 ] && [ "$2" = claude-code ]; }
  printf 'E:/Project/example\n' > "$(agmsg_project_marker_path 4242)"
  [ "$(agmsg_read_project_marker 4242 claude-code)" = E:/Project/example ]
}

@test "project marker GC: unknown native liveness is preserved" {
  agmsg_write_project_marker 4242 E:/Project/unknown-owner
  compat_pid_state_native() { echo unknown; }
  agmsg_marker_gc_stale
  [ -f "$(agmsg_project_marker_path 4242)" ]
}

@test "owner state: live Claude is alive, PID reuse by another command is dead" {
  force_platform msys
  compat_pid_state_native() { echo alive; }
  compat_native_process_record() { printf '1\x1f12345\x1fclaude.exe\x1fC:/Claude/claude.exe\x1f"C:/Claude/claude.exe" --resume x'; }
  [ "$(agmsg_instance_owner_state sid.7000 claude-code 12345)" = alive ]
  compat_native_process_record() { printf '1\x1f12345\x1fnotepad.exe\x1fC:/Windows/notepad.exe\x1fC:/Windows/notepad.exe claude'; }
  [ "$(agmsg_instance_owner_state sid.7000 claude-code 12345)" = dead ]
}

@test "native matcher: identity fields recognize Claude but not a trailing argument" {
  [ "$(_agmsg_native_identity_fields_state claude-code claude.exe C:/Windows/notepad.exe 'C:/Node/node.exe wrapper.js')" = match ]
  [ "$(_agmsg_native_identity_fields_state claude-code node.exe C:/Claude/claude.exe 'C:/Node/node.exe wrapper.js')" = match ]
  [ "$(_agmsg_native_identity_fields_state claude-code node.exe C:/Node/node.exe '"C:/Claude/claude.exe" --resume x')" = match ]
  [ "$(_agmsg_native_identity_fields_state claude-code node.exe C:/Node/node.exe 'C:/Node/node.exe wrapper.js claude')" = no-match ]
}

@test "owner generation: same WINPID and Claude identity with different CreationDate is dead" {
  force_platform msys
  compat_pid_state_native() { echo alive; }
  compat_native_process_record() { printf '1\x1f99999\x1fclaude.exe\x1fC:/Claude/claude.exe\x1fC:/Claude/claude.exe'; }
  [ "$(agmsg_instance_owner_state sid.7000 claude-code 12345)" = dead ]
  [ "$(agmsg_instance_owner_state sid.7000 claude-code 99999)" = alive ]
}

@test "owner generation: missing CreationDate is unknown" {
  force_platform msys
  compat_pid_state_native() { echo alive; }
  compat_native_process_record() { printf '1\x1f\x1fclaude.exe\x1fC:/Claude/claude.exe\x1fC:/Claude/claude.exe'; }
  [ "$(agmsg_instance_owner_state sid.7000 claude-code 12345)" = unknown ]
}

@test "agent pid: Phase 1 conversion or revalidation failure safely continues Phase 2" {
  force_platform msys
  compat_get_ppid() { case "$1" in "$$") echo 10 ;; 10) echo 20 ;; *) echo 1 ;; esac; }
  agmsg_pid_is_agent() { [ "$1" = 20 ]; }
  compat_msys_pid_to_winpid() { case "$1" in 20) echo 2020 ;; 10) echo 1010 ;; esac; }
  agmsg_native_pid_is_agent() { return 1; }
  agmsg_native_pid_inspect() { case "$1" in 1010) printf 'no-match\t3030\t101' ;; 3030) printf 'match\t1\t102' ;; esac; }
  [ "$(agmsg_agent_pid claude-code)" = 3030 ]
  compat_msys_pid_to_winpid() { [ "$1" = 10 ] && echo 1010; }
  [ "$(agmsg_agent_pid claude-code)" = 3030 ]
}

@test "parallel resume: same sid with different native PIDs stays distinct" {
  [ "$(agmsg_instance_id_from_pid shared 7001)" = shared.7001 ]
  [ "$(agmsg_instance_id_from_pid shared 7002)" = shared.7002 ]
  [ "$(agmsg_instance_id_from_pid shared 7001)" != "$(agmsg_instance_id_from_pid shared 7002)" ]
}

@test "owner sidecar: successor record survives old watcher cleanup" {
  local original_umask
  original_umask="$(umask)"
  ( unset RUN_DIR; [ "$(agmsg_watch_owner_path fallback)" = "$SKILL_DIR/run/watch.fallback.owner" ] )
  agmsg_watch_owner_write sid.7000 111 claude-code native 12345
  [ "$(umask)" = "$original_umask" ]
  [ "$(agmsg_watch_owner_creation sid.7000 111 claude-code)" = 12345 ]
  agmsg_watch_owner_write sid.7000 222 claude-code native 67890
  agmsg_watch_owner_remove_if_watcher sid.7000 111
  [ "$(agmsg_watch_owner_creation sid.7000 222 claude-code)" = 67890 ]
  ! compgen -G "$RUN_DIR/watch.sid.7000.owner.*.tmp" >/dev/null
  agmsg_watch_owner_remove_if_watcher sid.7000 222
  [ ! -e "$RUN_DIR/watch.sid.7000.owner" ]
}

@test "retire helper: missing metadata, equal generation, and cmdline mismatch preserve incumbent" {
  start_native_claude_owner
  local iid="retire-safe.$OWNER_WINPID" pf="$RUN_DIR/watch.retire-safe.$OWNER_WINPID.pid"

  start_watch_standin
  echo "$STANDIN_PID" > "$pf"
  agmsg_watch_owner_write "$iid" "$STANDIN_PID" claude-code native ""
  ! agmsg_watch_retire_if_generation_changed "$iid" "$STANDIN_PID" claude-code "$OWNER_CREATION" "$SCRIPTS/watch.sh"
  kill -0 "$STANDIN_PID" 2>/dev/null
  [ -f "$pf" ]
  kill "$STANDIN_PID" 2>/dev/null || true; wait "$STANDIN_PID" 2>/dev/null || true

  start_watch_standin
  echo "$STANDIN_PID" > "$pf"
  agmsg_watch_owner_write "$iid" "$STANDIN_PID" claude-code native "$OWNER_CREATION"
  ! agmsg_watch_retire_if_generation_changed "$iid" "$STANDIN_PID" claude-code "$OWNER_CREATION" "$SCRIPTS/watch.sh"
  ! agmsg_watch_retire_if_generation_changed "$iid" "$STANDIN_PID" claude-code "" "$SCRIPTS/watch.sh"
  kill -0 "$STANDIN_PID" 2>/dev/null
  kill "$STANDIN_PID" 2>/dev/null || true; wait "$STANDIN_PID" 2>/dev/null || true

  sleep 180 &
  local unrelated=$!
  track_pid "$unrelated"
  echo "$unrelated" > "$pf"
  agmsg_watch_owner_write "$iid" "$unrelated" claude-code native "${OWNER_CREATION}0"
  ! agmsg_watch_retire_if_generation_changed "$iid" "$unrelated" claude-code "$OWNER_CREATION" "$SCRIPTS/watch.sh"
  kill -0 "$unrelated" 2>/dev/null
  [ "$(agmsg_watch_owner_creation "$iid" "$unrelated" claude-code)" = "${OWNER_CREATION}0" ]
}

@test "session-start retire: generation mismatch kills verified watcher and emits replacement directive" {
  start_native_claude_owner
  local iid="retire-session.$OWNER_WINPID" pf="$RUN_DIR/watch.retire-session.$OWNER_WINPID.pid"
  start_watch_standin
  echo "$STANDIN_PID" > "$pf"
  agmsg_watch_owner_write "$iid" "$STANDIN_PID" claude-code native "${OWNER_CREATION}0"

  run env AGMSG_AGENT_PID="$OWNER_WINPID" AGMSG_RESOLVE_PROJECT=0 \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"retire-session"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"invoke the Monitor tool"* ]]
  [[ "$output" == *"$OWNER_CREATION"* ]]
  wait_for_pid_exit "$STANDIN_PID"
  [ ! -e "$pf" ]
  [ ! -e "$(agmsg_watch_owner_path "$iid")" ]
}

@test "session-start dedup: missing, equal, or unverified owner keeps watcher and suppresses directive" {
  start_native_claude_owner
  local iid="keep-session.$OWNER_WINPID" pf="$RUN_DIR/watch.keep-session.$OWNER_WINPID.pid" out

  start_watch_standin
  echo "$STANDIN_PID" > "$pf"
  agmsg_watch_owner_write "$iid" "$STANDIN_PID" claude-code native ""
  out="$(env AGMSG_AGENT_PID="$OWNER_WINPID" AGMSG_RESOLVE_PROJECT=0 \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"keep-session"}')"
  [[ "$out" == *"already streaming"* ]]
  [[ "$out" != *"invoke the Monitor tool"* ]]
  kill -0 "$STANDIN_PID" 2>/dev/null
  kill "$STANDIN_PID" 2>/dev/null || true; wait "$STANDIN_PID" 2>/dev/null || true

  start_watch_standin
  echo "$STANDIN_PID" > "$pf"
  agmsg_watch_owner_write "$iid" "$STANDIN_PID" claude-code native "$OWNER_CREATION"
  out="$(env AGMSG_AGENT_PID="$OWNER_WINPID" AGMSG_RESOLVE_PROJECT=0 \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"keep-session"}')"
  [[ "$out" == *"already streaming"* ]]
  kill -0 "$STANDIN_PID" 2>/dev/null
  kill "$STANDIN_PID" 2>/dev/null || true; wait "$STANDIN_PID" 2>/dev/null || true

  sleep 180 &
  local unrelated=$!
  track_pid "$unrelated"
  echo "$unrelated" > "$pf"
  agmsg_watch_owner_write "$iid" "$unrelated" claude-code native "${OWNER_CREATION}0"
  out="$(env AGMSG_AGENT_PID="$OWNER_WINPID" AGMSG_RESOLVE_PROJECT=0 \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"keep-session"}')"
  [[ "$out" == *"already streaming"* ]]
  [[ "$out" != *"invoke the Monitor tool"* ]]
  kill -0 "$unrelated" 2>/dev/null
  [ -f "$pf" ]
}

@test "delivery retire: generation mismatch kills verified watcher and emits Monitor directive" {
  start_native_claude_owner
  local iid="retire-delivery.$OWNER_WINPID" pf="$RUN_DIR/watch.retire-delivery.$OWNER_WINPID.pid"
  start_watch_standin
  echo "$STANDIN_PID" > "$pf"
  agmsg_watch_owner_write "$iid" "$STANDIN_PID" claude-code native "${OWNER_CREATION}0"

  run env AGMSG_AGENT_PID="$OWNER_WINPID" CLAUDE_CODE_SESSION_ID=retire-delivery \
    bash "$SCRIPTS/delivery.sh" set monitor claude-code "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGMSG-DIRECTIVE"* ]]
  [[ "$output" == *"$OWNER_CREATION"* ]]
  wait_for_pid_exit "$STANDIN_PID"
  [ ! -e "$pf" ]
  [ ! -e "$(agmsg_watch_owner_path "$iid")" ]
}

@test "Windows watcher: live Claude owner is kept and owner exit stops it" {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "requires Git Bash on Windows" ;; esac
  cp /usr/bin/sleep.exe "$TEST_SKILL_DIR/claude.exe"
  "$TEST_SKILL_DIR/claude.exe" 120 & OWNER_MSYS_PID=$!
  local owner_winpid
  owner_winpid="$(compat_msys_pid_to_winpid "$OWNER_MSYS_PID")"
  case "$owner_winpid" in ''|*[!0-9]*) false ;; esac
  # Some managed sandboxes allow tasklist but deny Win32_Process details. That
  # environment is covered by the unknown/fail-closed unit case above; the real
  # lifecycle assertion needs executable identity and is run where CIM is
  # available (including the elevated Windows verification job).
  if ! compat_native_identity "$owner_winpid" >/dev/null 2>&1; then
    kill "$OWNER_MSYS_PID" 2>/dev/null || true
    wait "$OWNER_MSYS_PID" 2>/dev/null || true
    OWNER_MSYS_PID=""
    skip "Win32_Process identity query is unavailable"
  fi
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  local watcher_log="$TEST_SKILL_DIR/live-watcher.log"
  AGMSG_RESOLVE_PROJECT=0 AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "live.$owner_winpid" "$PROJ" claude-code >"$watcher_log" 2>&1 3>&- & WATCH_PID=$!
  local pf="$RUN_DIR/watch.live.$owner_winpid.pid" i
  for i in $(seq 1 50); do [ -f "$pf" ] && break; sleep 0.1; done
  [ -f "$pf" ] || { cat "$watcher_log"; false; }
  sleep 2
  kill -0 "$WATCH_PID" 2>/dev/null
  run bash "$SCRIPTS/delivery.sh" status claude-code "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 verified composite"* ]]

  kill "$OWNER_MSYS_PID" 2>/dev/null || true
  wait "$OWNER_MSYS_PID" 2>/dev/null || true
  OWNER_MSYS_PID=""
  for i in $(seq 1 50); do kill -0 "$WATCH_PID" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$WATCH_PID" 2>/dev/null
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=""
  [ ! -e "$pf" ]
}

@test "Windows watcher: bare UUID is not killed without owner evidence" {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "requires Git Bash on Windows" ;; esac
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  AGMSG_RESOLVE_PROJECT=0 AGMSG_AGENT_PID="" AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" bare-uuid "$PROJ" claude-code >/dev/null 2>&1 3>&- & WATCH_PID=$!
  local pf="$RUN_DIR/watch.bare-uuid.pid" i
  for i in $(seq 1 50); do [ -f "$pf" ] && break; sleep 0.1; done
  [ -f "$pf" ]
  sleep 2
  kill -0 "$WATCH_PID" 2>/dev/null
}

@test "Windows watcher: native inspection unknown does not exit watch.sh" {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "requires Git Bash on Windows" ;; esac
  cp /usr/bin/sleep.exe "$TEST_SKILL_DIR/claude.exe"
  "$TEST_SKILL_DIR/claude.exe" 120 & OWNER_MSYS_PID=$!
  local owner_winpid
  owner_winpid="$(compat_msys_pid_to_winpid "$OWNER_MSYS_PID")"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  _AGMSG_COMPAT_NO_CIM=1 AGMSG_RESOLVE_PROJECT=0 AGMSG_WATCH_INTERVAL=1 \
    bash "$SCRIPTS/watch.sh" "unknown.$owner_winpid" "$PROJ" claude-code "" 12345 >/dev/null 2>&1 3>&- & WATCH_PID=$!
  local pf="$RUN_DIR/watch.unknown.$owner_winpid.pid" i
  for i in $(seq 1 50); do [ -f "$pf" ] && break; sleep 0.1; done
  [ -f "$pf" ]
  sleep 2
  kill -0 "$WATCH_PID" 2>/dev/null
}

@test "Windows grok watcher: MSYS owner is kept and owner exit stops it" {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "requires Git Bash on Windows" ;; esac
  sleep 30 & OWNER_MSYS_PID=$!
  bash "$SCRIPTS/join.sh" team grok grok-build "$PROJ" >/dev/null
  AGMSG_RESOLVE_PROJECT=0 AGMSG_WATCH_INTERVAL=1 \
    bash "$SCRIPTS/watch.sh" "grok.$OWNER_MSYS_PID" "$PROJ" grok-build >/dev/null 2>&1 3>&- & WATCH_PID=$!
  local pf="$RUN_DIR/watch.grok.$OWNER_MSYS_PID.pid" i
  for i in $(seq 1 50); do [ -f "$pf" ] && break; sleep 0.1; done
  [ -f "$pf" ]
  sleep 2
  kill -0 "$WATCH_PID" 2>/dev/null
  kill "$OWNER_MSYS_PID" 2>/dev/null || true
  wait "$OWNER_MSYS_PID" 2>/dev/null || true
  OWNER_MSYS_PID=""
  for i in $(seq 1 50); do kill -0 "$WATCH_PID" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$WATCH_PID" 2>/dev/null
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=""
  [ ! -e "$pf" ]
}

@test "delivery status: distinguishes bare weak watcher from stale pidfile" {
  sleep 30 & OWNER_MSYS_PID=$!
  echo "$OWNER_MSYS_PID" > "$RUN_DIR/watch.bare-status.pid"
  echo 2147483647 > "$RUN_DIR/watch.stale-status.pid"
  run bash "$SCRIPTS/delivery.sh" status claude-code "$PROJ"
  kill "$OWNER_MSYS_PID" 2>/dev/null || true
  wait "$OWNER_MSYS_PID" 2>/dev/null || true
  OWNER_MSYS_PID=""
  [ "$status" -eq 0 ]
  [[ "$output" == *"watch processes: 1 alive, 1 stale pidfiles"* ]]
  [[ "$output" == *"1 bare weak"* ]]
}

@test "delivery set off: existing project-scoped watcher cleanup still works" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  AGMSG_RESOLVE_PROJECT=0 AGMSG_AGENT_PID="" AGMSG_WATCH_INTERVAL=30 \
    bash "$SCRIPTS/watch.sh" cleanup-sid "$PROJ" claude-code >/dev/null 2>&1 3>&- &
  WATCH_PID=$!
  local pf="$RUN_DIR/watch.cleanup-sid.pid" i
  for i in $(seq 1 80); do [ -f "$pf" ] && break; sleep 0.1; done
  [ -f "$pf" ]
  run bash "$SCRIPTS/delivery.sh" set off claude-code "$PROJ"
  [ "$status" -eq 0 ]
  for i in $(seq 1 80); do kill -0 "$WATCH_PID" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$WATCH_PID" 2>/dev/null
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=""
  [ ! -e "$pf" ]
}
