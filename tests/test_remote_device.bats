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
}

teardown() {
  local pidfile pid
  for pidfile in "$TEST_SKILL_DIR"/run/remote-sync.*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || continue
    kill "$pid" 2>/dev/null || true
    wait_for_pid_exit "$pid" || kill -KILL "$pid" 2>/dev/null || true
  done
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  teardown_test_env
}

# start_mock [VAR=value ...]: the fixture on an OS-assigned port, with the
# given knobs. Sets ENDPOINT.
# The team the fixture's pull side holds.
PULL_TEAM_ID=018f3f7e-2222-7000-8000-000000000002

start_mock() {
  : > "$TEST_SKILL_DIR/server.port"
  env "$@" "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  ENDPOINT="http://127.0.0.1:$(cat "$TEST_SKILL_DIR/server.port")"
}

# has <text> <needle> / lacks <text> <needle>: plain commands, so a failure
# ends the test on every bash (a non-last [[ ]] does not on 3.2).
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; return 0; }

device_state() { curl -sS "$ENDPOINT/_test/device-state"; }

# stop_engine: the connect started a background engine; take it down so the
# test, not the clock, decides when a push happens.
stop_engine() {
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid" pid
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile")"
  kill "$pid" 2>/dev/null || true
  wait_for_pid_exit "$pid" || true
  rm -f "$pidfile"
}

stop_engine_of() {
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.$1.pid" pid
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile")"
  kill "$pid" 2>/dev/null || true
  wait_for_pid_exit "$pid" || true
  rm -f "$pidfile"
}

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
  # The saved copy has done its job once the binding holds the address.
  [ ! -e "$TEST_SKILL_DIR/run/remote-credentials/device-address.testteam" ]
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
  [ ! -e "$TEST_SKILL_DIR/run/remote-credentials/device-address.testteam" ]
  run bash "$SCRIPTS/send.sh" testteam alice alice "still local"
  [ "$status" -eq 0 ]
}

@test "device connect: a failure after approval keeps the address, and the re-run does not ask again" {
  start_mock MOCK_FEATURES=device-approval MOCK_CONNECT_STATUS=500
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  [ -z "$(recorded_endpoint)" ]
  local saved="$TEST_SKILL_DIR/run/remote-credentials/device-address.testteam"
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
  [ ! -e "$saved" ]
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
  [ ! -e "$TEST_SKILL_DIR/run/remote-credentials/device-address.cloned" ]
  stop_engine_of cloned
}

@test "device pull: a server without the feature gets the manual pull" {
  start_mock MOCK_TEAM_CIPHER_PROFILE=none
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  [ "$(device_state | jq -r '.codes')" = 0 ]
  stop_engine_of cloned
}
