#!/usr/bin/env bats
#
# Connecting by device approval: the server says it offers it in the
# `features` array of its unauthenticated GET /v1/health; the user approves
# at a URL with a short code; the server hands the machine a data address.
# The server here is the fixture in helpers/mock_remote_server.py, standing in
# for any server that speaks the protocol.

load test_helper

setup() {
  setup_test_env
  export AGMSG_AGENT_PID=""
  MOCK_PYTHON3="$(command -v python3)"
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  MOCK_PID=""
  MOCK_PID2=""
}

teardown() {
  # Let a stand-in that waits on this file finish, whatever the test did.
  : > "$BATS_TEST_TMPDIR/go" 2>/dev/null || true
  # Only a process whose command line still names what this test started is
  # signalled: a pid read from a file, or kept from a launch, may have been
  # reused by something else since.
  local pidfile pid
  for pidfile in "$TEST_SKILL_DIR"/run/remote-sync.*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || continue
    ours_engine "$pid"
  done
  [ -z "$MOCK_PID" ] || ours_mock "$MOCK_PID"
  [ -z "$MOCK_PID2" ] || ours_mock "$MOCK_PID2"
  teardown_test_env
}

# pid_is_ours <pid> <fragment>...: true only when the pid's CURRENT command line
# contains every fragment. The fragments name what only this test started: its
# own install's absolute script path, or its own port file. A bare program name
# would also match another seat's or install's process after a pid is reused.
pid_is_ours() {
  local pid="$1" cmdline fragment; shift
  # shellcheck disable=SC1091
  . "$SCRIPTS/lib/compat.sh"
  cmdline="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  [ -n "$cmdline" ] || return 1
  for fragment in "$@"; do
    case "$cmdline" in *"$fragment"*) ;; *) return 1 ;; esac
  done
  return 0
}

# kill_if_ours <pid> <fragment>...: TERM, wait, and KILL only if it is STILL ours
# when the wait ends (the pid may have been recycled while we waited).
kill_if_ours() {
  local pid="$1"
  pid_is_ours "$@" || return 0
  kill "$pid" 2>/dev/null || true
  if ! wait_for_pid_exit "$pid"; then
    if pid_is_ours "$@"; then kill -KILL "$pid" 2>/dev/null || true; fi
  fi
}

# the engine this install started, and the mock this test started
ours_engine() { kill_if_ours "$1" "$SCRIPTS/internal/remote-sync.mjs"; }
ours_mock() { kill_if_ours "$1" "mock_remote_server.py" "$TEST_SKILL_DIR/"; }

# start_mock [VAR=value ...]: the fixture on an OS-assigned port, with the
# given knobs. Sets ENDPOINT.
# The team the fixture's pull side holds.
PULL_TEAM_ID=018f3f7e-2222-7000-8000-000000000002

start_mock() {
  : > "$TEST_SKILL_DIR/server.port"
  env "$@" "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 "$TEST_SKILL_DIR/server.port" \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  ENDPOINT="http://127.0.0.1:$(cat "$TEST_SKILL_DIR/server.port")"
}

# has <text> <needle> / lacks <text> <needle>: plain commands, so a failure
# ends the test on every bash (a non-last [[ ]] does not on 3.2).
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; return 0; }

# start_second_mock [VAR=value ...]: another server; sets ENDPOINT2.
start_second_mock() {
  local port_file="$TEST_SKILL_DIR/server2.port"
  : > "$port_file"
  env "$@" "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 "$port_file" \
    </dev/null > "$port_file" 2>"$TEST_SKILL_DIR/server2.log" 3>&- &
  MOCK_PID2=$!
  wait_for_file_contains "$port_file" '^[0-9][0-9]*$'
  ENDPOINT2="http://127.0.0.1:$(cat "$port_file")"
}

# saved_approvals: the saved approval files of the test's install.
saved_approvals() { ls "$TEST_SKILL_DIR"/run/remote-credentials/device-address.* 2>/dev/null || true; }

device_state() { curl -sS "$ENDPOINT/_test/device-state"; }

# stop_engine [team]: the connect started a background engine; take it down so
# the test, not the clock, decides when a push happens. Verified before
# signalling, like the teardown.
stop_engine() {
  local team="${1:-testteam}" pidfile pid
  pidfile="$TEST_SKILL_DIR/run/remote-sync.$team.pid"
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile")"
  ours_engine "$pid"
  rm -f "$pidfile"
}
stop_engine_of() { stop_engine "$1"; }

push_once() { bash "$SCRIPTS/remote-sync.sh" once --team testteam >/dev/null 2>&1 || true; }

# The message bodies the server holds, one per line. A cipher "none" envelope
# carries the message as the base64 of its JSON.
pushed_bodies() {
  curl -sS "$ENDPOINT/_test/pushed" |
    jq -r '.messages[].envelope.blob | @base64d | fromjson | .body'
}

# count_pushed <exact body> -> how many times the server holds it
count_pushed() {
  pushed_bodies | grep -cxF -- "$1" || true
}

recorded_endpoint() {
  jq -r '.remote_binding.endpoint // empty' "$TEST_SKILL_DIR/teams/testteam/config.json"
}

@test "device connect: a server that lists no features gets the manual connect, and no device route is called" {
  start_mock
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  has "$output" "Connected: team 'testteam'"
  [ "$(device_state | jq -r '.codes + .polls + .activations')" = 0 ]
  [ "$(recorded_endpoint)" = "$ENDPOINT" ]
}

@test "device connect: a features list without device-approval gets the manual connect" {
  start_mock MOCK_FEATURES=roster-snapshot
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.codes')" = 0 ]
  [ "$(recorded_endpoint)" = "$ENDPOINT" ]
}

@test "manual connect keeps uploading the existing history" {
  start_mock
  bash "$SCRIPTS/send.sh" testteam alice alice "before the connect" >/dev/null
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam >/dev/null
  stop_engine
  push_once
  [ "$(count_pushed "before the connect")" = 1 ]
}

@test "device connect: approves, activates, records the address, and never prints it" {
  start_mock MOCK_FEATURES=device-approval
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  has "$output" "http://approve.example/device?user_code=ABCD-2345"
  has "$output" "ABCD-2345"
  has "$output" "Connected: team 'testteam'"
  # The data address is a capability: it is recorded, and it is on no screen.
  lacks "$output" "mocksecret"
  case "$(recorded_endpoint)" in "$ENDPOINT/t/mocksecret"*) ;; *) return 1 ;; esac
  [ "$(device_state | jq -r '.codes')" = 1 ]
  [ "$(device_state | jq -r '.activations')" = 1 ]
  [ "$(device_state | jq -r '.bad_activations')" = 0 ]
  # It asked for the machine name and the registered client, nothing else.
  [ "$(device_state | jq -r '.last_code_body.client_id')" = "agmsg-cli" ]
  [ "$(device_state | jq -r '.last_code_body.scope')" = "login" ]
  # The grant names the team being connected, so the owner has nothing to choose
  # and a server that holds no team yet can still approve.
  [ "$(device_state | jq -r '.last_code_body.team_id')" = "$(jq -r '.team_id' "$TEST_SKILL_DIR/teams/testteam/config.json")" ]
  # The saved copy has done its job once the binding holds the address.
  [ -z "$(saved_approvals)" ]
}

@test "device connect: --machine-name labels this machine, and a name already taken says how to choose another" {
  start_mock MOCK_FEATURES=device-approval
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --machine-name second-install testteam
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.last_code_body.machine_name')" = "second-install" ]
}

@test "device connect: an explicit --machine-name is sent exactly as given" {
  start_mock MOCK_FEATURES=device-approval
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --machine-name "My laptop (työ) \"2\"" testteam
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.last_code_body.machine_name')" = 'My laptop (työ) "2"' ]
}

# A marker that matches on this machine: the shipped list names a path no test
# machine has, so the test installs its own list in its own copy of the scripts.
marker_dir() {
  mkdir -p "$BATS_TEST_TMPDIR/hosted/skills"
  printf '# test list\nhosted dir %s\nabsent dir %s\n' \
    "$BATS_TEST_TMPDIR/hosted/skills" "$BATS_TEST_TMPDIR/not-there" > "$SCRIPTS/drivers/env-markers.conf"
}

@test "device connect: sends the ids of the matched markers to a server that lists env-markers" {
  marker_dir
  start_mock MOCK_FEATURES=device-approval,env-markers
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -c '.last_code_body.env_markers')" = '["hosted"]' ]
  # Ids only: the path that matched is nowhere in the request.
  [ "$(device_state | jq -c '.last_code_body' | grep -c "$BATS_TEST_TMPDIR" || true)" = "0" ]
}

@test "device connect: sends no env_markers to a server that does not list env-markers" {
  marker_dir
  start_mock MOCK_FEATURES=device-approval
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.last_code_body | has("env_markers")')" = "false" ]
}

@test "device connect: sends no env_markers when none matches" {
  printf 'hosted dir %s\n' "$BATS_TEST_TMPDIR/not-there" > "$SCRIPTS/drivers/env-markers.conf"
  start_mock MOCK_FEATURES=device-approval,env-markers
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.last_code_body | has("env_markers")')" = "false" ]
}

@test "env markers: a list line that does not parse is skipped, a repeat is sent once" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  {
    printf '# comment\n\n'
    printf 'Bad dir %s\n' "$BATS_TEST_TMPDIR/d"
    printf 'rel dir relative/path\n'
    printf 'two dir %s extra\n' "$BATS_TEST_TMPDIR/d"
    printf 'odd file %s\n' "$BATS_TEST_TMPDIR/d"
    printf 'ok-1 dir %s\n' "$BATS_TEST_TMPDIR/d"
    printf 'ok-1 dir %s\n' "$BATS_TEST_TMPDIR/d"
    printf 'last dir %s' "$BATS_TEST_TMPDIR/d"
  } > "$SCRIPTS/drivers/env-markers.conf"
  run bash -c ". '$SCRIPTS/lib/env-markers.sh'; agmsg_env_markers"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ok-1\nlast')" ]
}

@test "env markers: the shipped list names muse and its check is the directory /opt/muse/skills" {
  run grep -E '^muse dir /opt/muse/skills$' "$BATS_TEST_DIRNAME/../scripts/drivers/env-markers.conf"
  [ "$status" -eq 0 ]
}

@test "device connect: a --machine-name the server would refuse stops before it is asked" {
  start_mock MOCK_FEATURES=device-approval
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --machine-name " padded " testteam
  [ "$status" -eq 1 ]
  has "$output" "nothing was changed"
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --machine-name "$(printf 'a%.0s' $(seq 1 129))" testteam
  [ "$status" -eq 1 ]
  [ "$(device_state | jq -r '.codes')" = 0 ]
  [ -z "$(recorded_endpoint)" ]
}

@test "device connect: a machine name the server already holds is reported with the way out" {
  start_mock MOCK_FEATURES=device-approval MOCK_DEVICE_ERROR=machine_exists
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  has "$output" "already connected to this team"
  has "$output" "--machine-name"
  has "$output" "nothing was changed"
  [ -z "$(recorded_endpoint)" ]
  [ -z "$(saved_approvals)" ]
}

@test "device connect: the history is not uploaded unless asked, and a message written while approving is" {
  start_mock MOCK_FEATURES=device-approval MOCK_DEVICE_PENDING=1000000 MOCK_DEVICE_INTERVAL=1
  bash "$SCRIPTS/send.sh" testteam alice alice "written before the command" >/dev/null
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam \
    > "$TEST_SKILL_DIR/connect.out" 2>&1 &
  local connect_pid=$!
  local waited=0
  until [ "$(device_state | jq -r '.polls')" -ge 1 ]; do
    sleep 1; waited=$((waited + 1))
    [ "$waited" -lt 30 ]
  done
  bash "$SCRIPTS/send.sh" testteam alice alice "written while approving" >/dev/null
  curl -sS "$ENDPOINT/_test/device-approve" >/dev/null
  wait "$connect_pid"
  stop_engine
  push_once
  push_once
  # Sent, once: not lost and not duplicated.
  [ "$(count_pushed "written while approving")" = 1 ]
  # Left where it was.
  [ "$(count_pushed "written before the command")" = 0 ]
  run bash "$SCRIPTS/history.sh" testteam alice
  has "$output" "written before the command"
}

@test "device connect: --with-history uploads the history as the manual connect does" {
  start_mock MOCK_FEATURES=device-approval
  bash "$SCRIPTS/send.sh" testteam alice alice "written before the command" >/dev/null
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --with-history testteam
  [ "$status" -eq 0 ]
  stop_engine
  push_once
  [ "$(count_pushed "written before the command")" = 1 ]
}

@test "device connect: a denied approval changes nothing and the local team still works" {
  start_mock MOCK_FEATURES=device-approval MOCK_DEVICE_ERROR=access_denied
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  has "$output" "denied"
  has "$output" "nothing was changed"
  [ -z "$(recorded_endpoint)" ]
  [ -z "$(saved_approvals)" ]
  run bash "$SCRIPTS/send.sh" testteam alice alice "still local"
  [ "$status" -eq 0 ]
}

@test "device connect: a failure after approval keeps the address, and the re-run does not ask again" {
  start_mock MOCK_FEATURES=device-approval MOCK_CONNECT_STATUS=500
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  [ -z "$(recorded_endpoint)" ]
  local saved
  saved="$(saved_approvals)"
  [ -s "$saved" ]
  # Readable by this user only.
  case "$(uname)" in
    Darwin) [ "$(stat -f %Lp "$saved")" = 600 ] ;;
    *)      [ "$(stat -c %a "$saved")" = 600 ] ;;
  esac
  # The local team is usable.
  bash "$SCRIPTS/send.sh" testteam alice alice "still local" >/dev/null
  curl -sS "$ENDPOINT/_test/connect-status?value=" >/dev/null
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  has "$output" "Connected: team 'testteam'"
  [ "$(device_state | jq -r '.codes')" = 1 ]
  [ -z "$(saved_approvals)" ]
}

@test "device connect: a message written after a failed first attempt is still sent by the re-run" {
  start_mock MOCK_FEATURES=device-approval MOCK_CONNECT_STATUS=500
  bash "$SCRIPTS/send.sh" testteam alice alice "written before the command" >/dev/null
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  bash "$SCRIPTS/send.sh" testteam alice alice "written after the first attempt" >/dev/null
  curl -sS "$ENDPOINT/_test/connect-status?value=" >/dev/null
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  stop_engine
  push_once
  [ "$(count_pushed "written after the first attempt")" = 1 ]
  [ "$(count_pushed "written before the command")" = 0 ]
}

@test "device connect: an approval made at one server is never offered to another" {
  start_mock MOCK_FEATURES=device-approval MOCK_CONNECT_STATUS=500
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  local first="$ENDPOINT"
  start_second_mock MOCK_FEATURES=device-approval
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT2" testteam
  [ "$status" -eq 0 ]
  # The second server was asked for its own approval, and the team is bound to it.
  [ "$(curl -sS "$ENDPOINT2/_test/device-state" | jq -r '.codes')" = 1 ]
  case "$(recorded_endpoint)" in "$ENDPOINT2"/t/*) ;; *) return 1 ;; esac
  # The first server's approval is still saved, under its own name.
  [ "$(saved_approvals | wc -l | tr -d ' ')" = 1 ]
}

@test "device connect: an approved address the data side calls invalid is dropped, even once activated, and the next run asks again" {
  start_mock MOCK_FEATURES=device-approval MOCK_CONNECT_STATUS=500
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  # Activated and saved: the 500 came after the activation took.
  [ "$(saved_approvals | head -1 | xargs sed -n 3p)" = 1 ]
  # The credential is revoked behind our back; the re-run reuses the saved record
  # and is told so.
  curl -sS "$ENDPOINT/_test/connect-status?value=401" >/dev/null
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  has "$output" "saved approval was dropped"
  [ -z "$(saved_approvals)" ]
  # And the way back is open: a new approval.
  curl -sS "$ENDPOINT/_test/connect-status?value=" >/dev/null
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.codes')" = 2 ]
}

@test "device connect: a data-side server error keeps the saved approval (not every failure is terminal)" {
  start_mock MOCK_FEATURES=device-approval MOCK_CONNECT_STATUS=503
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  [ -s "$(saved_approvals)" ]
  lacks "$output" "dropped"
}

@test "device connect: an activation the server could not take keeps the approval and the re-run retries it" {
  start_mock MOCK_FEATURES=device-approval MOCK_DEVICE_ACTIVATE_STATUS=503
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  has "$output" "approval is kept"
  [ -s "$(saved_approvals)" ]
  [ -z "$(recorded_endpoint)" ]
  curl -sS "$ENDPOINT/_test/activate-status?value=" >/dev/null
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  # Not asked to approve again; the activation that failed was retried and took.
  [ "$(device_state | jq -r '.codes')" = 1 ]
  [ "$(device_state | jq -r '.failed_activations')" = 1 ]
  [ "$(device_state | jq -r '.activations')" = 1 ]
  [ -z "$(saved_approvals)" ]
}

@test "device connect: the approved address is on no process command line" {
  start_mock MOCK_FEATURES=device-approval
  # Node is the one program the address is handed to; record every argv it gets.
  local real_node wrapper="$BATS_TEST_TMPDIR/node-argv"
  real_node="$(command -v node)"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' \
    "$BATS_TEST_TMPDIR/node-argv.log" "$real_node" > "$wrapper"
  chmod +x "$wrapper"
  : > "$BATS_TEST_TMPDIR/node-argv.log"
  AGMSG_NODE="$wrapper" run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  # Non-vacuity: node was run, and with arguments.
  [ -s "$BATS_TEST_TMPDIR/node-argv.log" ]
  lacks "$(cat "$BATS_TEST_TMPDIR/node-argv.log")" "mocksecret"
  stop_engine
}

@test "device pull: the approved address is on no node command line" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none
  local real_node wrapper="$BATS_TEST_TMPDIR/node-argv"
  real_node="$(command -v node)"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' \
    "$BATS_TEST_TMPDIR/node-argv.log" "$real_node" > "$wrapper"
  chmod +x "$wrapper"
  : > "$BATS_TEST_TMPDIR/node-argv.log"
  AGMSG_NODE="$wrapper" run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/node-argv.log" ]
  lacks "$(cat "$BATS_TEST_TMPDIR/node-argv.log")" "mocksecret"
  stop_engine cloned
}

@test "remote.sh hands no endpoint to another program on its command line" {
  # The shell side of the same rule, which a node wrapper cannot see: a
  # remote-sync.sh call that names the endpoint in its arguments. The endpoint
  # may be an approved address, which is a credential.
  run grep -nE '(--endpoint|--server)[ =]"?\$\{?endpoint' "$SCRIPTS/remote.sh"
  [ "$status" -eq 1 ]
}

@test "device connect: a storage driver that cannot start from now stops before anything is asked" {
  start_mock MOCK_FEATURES=device-approval
  export AGMSG_STORAGE_DRIVER=jsonl
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/jsonl-store"
  bash "$SCRIPTS/join.sh" jteam alice claude-code /tmp/project-j >/dev/null 2>&1 || true
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" jteam
  [ "$status" -eq 1 ]
  has "$output" "cannot start from now"
  has "$output" "--with-history"
  [ "$(device_state | jq -r '.codes')" = 0 ]
}

@test "device connect: a team that is already connected stays as it is" {
  start_mock
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam >/dev/null
  stop_engine
  curl -sS "$ENDPOINT/_test/features?value=device-approval" >/dev/null
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  has "$output" "already connected"
  [ "$(device_state | jq -r '.codes')" = 0 ]
  [ "$(recorded_endpoint)" = "$ENDPOINT" ]
}

@test "device pull: the machine is approved, takes the team the server answers with, and keeps the address off screen" {
  # A plain team: the fixture's default declaration is sealed, and a sealed team
  # with no key here is locked, which is a different test.
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  has "$output" "Pulled "
  lacks "$output" "mocksecret"
  [ "$(device_state | jq -r '.codes')" = 1 ]
  [ "$(device_state | jq -r '.activations')" = 1 ]
  [ -f "$TEST_SKILL_DIR/teams/cloned/config.json" ]
  [ -z "$(saved_approvals)" ]
  stop_engine_of cloned
}

@test "device pull: the team the approval names is used, so no name lookup is made and --team-id is not needed" {
  # MOCK_LOOKUP_BAD makes every name lookup fail: a pull that still succeeds did
  # not make one.
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none MOCK_LOOKUP_BAD=http_error \
    MOCK_DEVICE_TOKEN_TEAM_ID="$PULL_TEAM_ID" MOCK_DEVICE_TOKEN_TEAM_NAME=cloned
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 0 ]
  has "$output" "Pulled "
  [ "$(jq -r '.team_id' "$TEST_SKILL_DIR/teams/cloned/config.json")" = "$PULL_TEAM_ID" ]
  stop_engine_of cloned
}

@test "device pull: --team-id equal to the approval's team is accepted" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none \
    MOCK_DEVICE_TOKEN_TEAM_ID="$PULL_TEAM_ID" MOCK_DEVICE_TOKEN_TEAM_NAME=anything
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  [ "$(jq -r '.team_id' "$TEST_SKILL_DIR/teams/cloned/config.json")" = "$PULL_TEAM_ID" ]
  stop_engine_of cloned
}

@test "device pull: asked for a team by name, an approval for another team stops before anything is written" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none \
    MOCK_DEVICE_TOKEN_TEAM_ID="$PULL_TEAM_ID" MOCK_DEVICE_TOKEN_TEAM_NAME=other-team
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 1 ]
  has "$output" "you asked for team 'cloned', but the approval is for team 'other-team' ($PULL_TEAM_ID); nothing was changed."
  has "$output" "to pull that team, run: bash "
  has "$output" "pull --endpoint '$ENDPOINT' --team-id '$PULL_TEAM_ID' --machine-name '"
  has "$output" "-r"
  lacks "$output" "pull --endpoint '$ENDPOINT' 'other-team'"
  [ ! -e "$TEST_SKILL_DIR/teams/cloned" ]
  [ -z "$(saved_approvals)" ]
  [ "$(device_state | jq -r '.activations')" = 0 ]
}

@test "device pull: --team-id that differs from the approval's team stops the same way" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none \
    MOCK_DEVICE_TOKEN_TEAM_ID="$PULL_TEAM_ID" MOCK_DEVICE_TOKEN_TEAM_NAME=other-team
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id 01900000-0000-7000-8000-00000000dead cloned
  [ "$status" -eq 1 ]
  has "$output" "you asked for team id 01900000-0000-7000-8000-00000000dead, but the approval is for team 'other-team' ($PULL_TEAM_ID); nothing was changed."
  [ ! -e "$TEST_SKILL_DIR/teams/cloned" ]
  [ -z "$(saved_approvals)" ]
}

@test "device pull: the command a mismatch prints completes the pull, on a server that keeps one device per name" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none MOCK_DEVICE_UNIQUE_NAMES=1 \
    MOCK_DEVICE_TOKEN_TEAM_ID="$PULL_TEAM_ID" MOCK_DEVICE_TOKEN_TEAM_NAME=other-team
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 1 ]
  local printed
  printed="$(printf '%s\n' "$output" | sed -n 's/^agmsg: to pull that team, run: //p')"
  [ -n "$printed" ]
  # The same command with the machine name the first attempt used is refused: the
  # server already holds a device under it.
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 1 ]
  has "$output" "already connected"
  # The printed command, as printed, finishes the pull.
  run bash -c "$printed"
  [ "$status" -eq 0 ]
  has "$output" "Pulled "
  [ "$(jq -r '.team_id' "$TEST_SKILL_DIR/teams/cloned/config.json")" = "$PULL_TEAM_ID" ]
  stop_engine_of cloned
}

@test "device pull: a saved approval for another team prints the runnable command and the file, and that command finishes the pull" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none MOCK_DATA_STATUS=503 \
    MOCK_DEVICE_TOKEN_TEAM_ID="$PULL_TEAM_ID" MOCK_DEVICE_TOKEN_TEAM_NAME=cloned
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 1 ]
  [ -s "$(saved_approvals)" ]
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id 01900000-0000-7000-8000-00000000dead cloned
  [ "$status" -eq 1 ]
  has "$output" "you asked for team id 01900000-0000-7000-8000-00000000dead, but the saved approval is for team id $PULL_TEAM_ID; nothing was changed."
  has "$output" "to approve again instead, remove $(saved_approvals) and run the command again."
  local printed
  printed="$(printf '%s\n' "$output" | sed -n 's/^agmsg: to pull that team, run: //p')"
  has "$printed" "pull --endpoint '$ENDPOINT' --team-id '$PULL_TEAM_ID' 'cloned'"
  curl -sS "$ENDPOINT/_test/data-status?value=" >/dev/null
  run bash -c "$printed"
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.codes')" = 1 ]
  stop_engine_of cloned
}

@test "device pull: the rerun command carries the team name as given, however long or non-ASCII" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none \
    MOCK_DEVICE_TOKEN_TEAM_ID="$PULL_TEAM_ID" MOCK_DEVICE_TOKEN_TEAM_NAME=other
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id 01900000-0000-7000-8000-00000000dead cloned
  [ "$status" -eq 1 ]
  lacks "$output" "pull --endpoint '$ENDPOINT' 'other'"
  has "$output" "'cloned'"
}

@test "device pull: the other team's name is shown as printable text only" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none \
    MOCK_DEVICE_TOKEN_TEAM_ID="$PULL_TEAM_ID" MOCK_DEVICE_TOKEN_TEAM_NAME=$'evil\x1b[2Jname'
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 1 ]
  has "$output" "approval is for team 'evil"
  lacks "$output" $'\x1b'
}

@test "device pull: a team id without its name is not used" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none MOCK_LOOKUP_BAD=http_error \
    MOCK_DEVICE_TOKEN_TEAM_ID="$PULL_TEAM_ID"
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 1 ]
  has "$output" "could not look up"
}

@test "device pull: a team id that is not a UUID is not used either" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none MOCK_LOOKUP_BAD=http_error \
    MOCK_DEVICE_TOKEN_TEAM_ID="../not-a-uuid" MOCK_DEVICE_TOKEN_TEAM_NAME=cloned
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 1 ]
  has "$output" "could not look up"
}

@test "device pull: the team the approval named is kept with a saved approval, so the re-run needs no lookup" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none MOCK_LOOKUP_BAD=http_error \
    MOCK_DEVICE_TOKEN_TEAM_ID="$PULL_TEAM_ID" MOCK_DEVICE_TOKEN_TEAM_NAME=cloned MOCK_DATA_STATUS=503
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 1 ]
  [ "$(sed -n 4p "$(saved_approvals)")" = "$PULL_TEAM_ID" ]
  curl -sS "$ENDPOINT/_test/data-status?value=" >/dev/null
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.codes')" = 1 ]
  stop_engine_of cloned
}

@test "device pull: a bootstrap the data side refuses as invalid drops the approval, and the next run approves again" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none MOCK_DATA_STATUS=401
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 1 ]
  has "$output" "saved approval was dropped"
  [ -z "$(saved_approvals)" ]
  curl -sS "$ENDPOINT/_test/data-status?value=" >/dev/null
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.codes')" = 2 ]
  stop_engine cloned
}

@test "device pull: the engine's progress reaches the terminal while the pull is still running" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none
  # Stand in for the engine's bootstrap: print a progress line, wait to be told
  # to go on, then fail. A pull that held the engine's output until it ended
  # would show nothing until then.
  local real="$SCRIPTS/remote-sync.sh" go="$BATS_TEST_TMPDIR/go"
  mv "$real" "$real.real"
  cat > "$real" <<STUB
#!/usr/bin/env bash
if [ "\$1" = pull-bootstrap ]; then
  echo "PROGRESS-MARKER-1" >&2
  while [ ! -e "$go" ]; do sleep 0.2; done
  exit 1
fi
exec bash "$real.real" "\$@"
STUB
  chmod +x "$real"
  bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned \
    > "$BATS_TEST_TMPDIR/pull.out" 2>&1 3>&- &
  local pull_pid=$! waited=0
  until grep -q PROGRESS-MARKER-1 "$BATS_TEST_TMPDIR/pull.out" 2>/dev/null; do
    sleep 0.5; waited=$((waited + 1))
    [ "$waited" -lt 40 ]
  done
  # Seen while the stand-in is still waiting: it is streamed, not held.
  [ ! -e "$go" ]
  kill -0 "$pull_pid"
  touch "$go"
  wait "$pull_pid" || true
}

@test "device pull: a name lookup the data side refuses as invalid drops the approval too" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none MOCK_DATA_STATUS=401
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 1 ]
  has "$output" "saved approval was dropped"
  [ -z "$(saved_approvals)" ]
}

@test "device pull: a refusal that is not JSON still drops the approval (401), and a non-JSON 503 keeps it" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none MOCK_DATA_STATUS=401 MOCK_DATA_BODY=text
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 1 ]
  has "$output" "saved approval was dropped"
  [ -z "$(saved_approvals)" ]
  # The name lookup reads the answer through a different helper.
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -eq 1 ]
  has "$output" "saved approval was dropped"
  [ -z "$(saved_approvals)" ]
  # Weather is not a refusal, whatever the body.
  curl -sS "$ENDPOINT/_test/data-status?value=503&body=text" >/dev/null
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 1 ]
  lacks "$output" "dropped"
  [ -s "$(saved_approvals)" ]
}

@test "device pull: a data-side server error keeps the saved approval" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none MOCK_DATA_STATUS=503
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 1 ]
  lacks "$output" "dropped"
  [ -s "$(saved_approvals)" ]
}

@test "device pull: the team id is sent when it is known, and left out when it is not" {
  start_mock MOCK_FEATURES=device-approval MOCK_TEAM_CIPHER_PROFILE=none
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.last_code_body.team_id')" = "$PULL_TEAM_ID" ]
  stop_engine cloned
  # By name there is nothing to send before the approval: the owner chooses.
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" named
  [ "$(device_state | jq -r '.last_code_body | has("team_id")')" = false ]
  stop_engine named
}

@test "device pull: a server without the feature gets the manual pull" {
  start_mock MOCK_TEAM_CIPHER_PROFILE=none
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.codes')" = 0 ]
  stop_engine_of cloned
}
