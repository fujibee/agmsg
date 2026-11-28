#!/usr/bin/env bats
#
# Key escrow on a device-approved connect and pull: a server that lists
# `key-escrow` in its unauthenticated GET /v1/health keeps a wrapped copy of the
# team key. The server here is the fixture in helpers/mock_remote_server.py,
# which seals the key bundle with the real age tool.

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


ESCROW_FEATURES="device-approval,key-escrow"

@test "escrow connect: a new team becomes age-v1, the device key is registered and epoch 1 is sent" {
  start_mock MOCK_FEATURES="$ESCROW_FEATURES"
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  has "$output" "This server keeps a wrapped copy of the team key"
  lacks "$output" "Back this up now"
  lacks "$output" "AGE-SECRET-KEY"
  lacks "$output" "mocksecret"
  [ "$(jq -r '.remote_binding.cipher_profile' "$TEST_SKILL_DIR/teams/testteam/config.json")" = "age-v1" ]
  state="$(curl -sS "$ENDPOINT/_test/escrow-state")"
  [ "$(printf '%s' "$state" | jq -r '.registrations')" = 1 ]
  [ "$(printf '%s' "$state" | jq -r '.last_registration | has("label")')" = true ]
  [ "$(printf '%s' "$state" | jq -r '.epoch_count')" = 1 ]
  [ "$(printf '%s' "$state" | jq -r '.first_epoch.epoch')" = 1 ]
  [ "$(printf '%s' "$state" | jq -r '.first_epoch.key_id')" = "$(jq -r '.remote_key.current.key_id' "$TEST_SKILL_DIR/teams/testteam/config.json")" ]
  stop_engine testteam
}

@test "escrow connect: the same key is accepted again, so the retry command is safe to repeat" {
  start_mock MOCK_FEATURES="$ESCROW_FEATURES"
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  stop_engine testteam
  run bash "$SCRIPTS/remote.sh" escrow-publish testteam
  [ "$status" -eq 0 ]
  [ "$(curl -sS "$ENDPOINT/_test/escrow-state" | jq -r '.epoch_count')" = 1 ]
  stop_engine testteam
}

@test "escrow connect: a server without key-escrow keeps today's plain device connect" {
  start_mock MOCK_FEATURES=device-approval
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [ "$(jq -r '.remote_binding.cipher_profile' "$TEST_SKILL_DIR/teams/testteam/config.json")" = "none" ]
  [ "$(curl -sS "$ENDPOINT/_test/escrow-state" | jq -r '.registrations')" = 0 ]
  stop_engine testteam
}

@test "escrow connect: a team with its own key stays on the manual key and the command says so" {
  start_mock MOCK_FEATURES="$ESCROW_FEATURES"
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  has "$output" "has its own key, so this server's key escrow is not used for it"
  [ "$(curl -sS "$ENDPOINT/_test/escrow-state" | jq -r '.registrations')" = 0 ]
  [ "$(curl -sS "$ENDPOINT/_test/escrow-state" | jq -r '.epoch_count')" = 0 ]
  stop_engine testteam
}

@test "escrow connect: --e2ee is the manual path, even on an escrow server" {
  start_mock MOCK_FEATURES="$ESCROW_FEATURES"
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam
  [ "$(curl -sS "$ENDPOINT/_test/escrow-state" | jq -r '.registrations')" = 0 ]
  [ "$(curl -sS "$ENDPOINT/_test/escrow-state" | jq -r '.epoch_count')" = 0 ]
  stop_engine testteam
}

@test "escrow connect: a different key already held for epoch 1 stops it, saying so, and starts no engine" {
  start_mock MOCK_FEATURES="$ESCROW_FEATURES" MOCK_ESCROW_PRELOAD_KEY_ID=someone-elses-key
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 1 ]
  has "$output" "the server already holds a different key for this team's first epoch"
  has "$output" "the team key was not sent and no sync engine was started"
  has "$output" "escrow-publish 'testteam'"
  [ ! -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
  [ "$(curl -sS "$ENDPOINT/_test/escrow-state" | jq -r '.epoch_count')" = 1 ]
}

# A machine that connected a team (so the server holds its key) and then pulls the
# same team under another local name, as a second machine would.
second_machine_pull() {
  tid="$(jq -r '.team_id' "$TEST_SKILL_DIR/teams/testteam/config.json")"
  start_mock MOCK_FEATURES="$ESCROW_FEATURES" MOCK_PULL_TEAM_ID="$tid" MOCK_TEAM_CIPHER_PROFILE=age-v1 \
    MOCK_ESCROW_DEVICE_REPLACE=1 "$@"
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  stop_engine testteam
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$tid" cloned
}

@test "escrow pull: the key bundle is fetched, opened and imported, and the team unlocks" {
  second_machine_pull
  [ "$status" -eq 0 ]
  has "$output" "The team key came from the server's escrow."
  lacks "$output" "AGE-SECRET-KEY"
  [ "$(jq -r '.remote_key.current.key_id' "$TEST_SKILL_DIR/teams/cloned/config.json")" = \
    "$(jq -r '.remote_key.current.key_id' "$TEST_SKILL_DIR/teams/testteam/config.json")" ]
  [ -f "$TEST_SKILL_DIR/run/remote-credentials/cloned/keys/$(jq -r '.remote_key.current.key_id' "$TEST_SKILL_DIR/teams/cloned/config.json").key" ]
  [ "$(curl -sS "$ENDPOINT/_test/escrow-state" | jq -r '.bundle_gets')" = 1 ]
  stop_engine cloned
}

@test "escrow pull: a digest the server reports that is not the bundle's installs nothing" {
  second_machine_pull MOCK_ESCROW_BUNDLE_DIGEST=wrong
  has "$output" "the key bundle's snapshot digest differs from the one the server reported; nothing was installed"
  has "$output" "escrow-install 'cloned'"
  [ -z "$(jq -r '.remote_key.current.key_id // empty' "$TEST_SKILL_DIR/teams/cloned/config.json")" ]
  [ ! -e "$TEST_SKILL_DIR/run/remote-credentials/cloned/keys" ] || [ -z "$(ls "$TEST_SKILL_DIR/run/remote-credentials/cloned/keys")" ]
  [ ! -f "$TEST_SKILL_DIR/run/remote-sync.cloned.pid" ]
}

@test "escrow pull: a bundle whose private key is not the epoch's installs nothing" {
  second_machine_pull MOCK_ESCROW_TAMPER=identity
  has "$output" "its key could not be installed from the server"
  [ -z "$(jq -r '.remote_key.current.key_id // empty' "$TEST_SKILL_DIR/teams/cloned/config.json")" ]
  [ ! -f "$TEST_SKILL_DIR/run/remote-sync.cloned.pid" ]
}

@test "escrow pull: a server that holds no key for the team says so and installs nothing" {
  start_mock MOCK_FEATURES="$ESCROW_FEATURES" MOCK_TEAM_CIPHER_PROFILE=age-v1
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  has "$output" "the server holds no key for this team yet; nothing was installed."
  [ -z "$(jq -r '.remote_key.current.key_id // empty' "$TEST_SKILL_DIR/teams/cloned/config.json")" ]
}

@test "escrow pull: a pull that is not by device approval never asks the server for a key" {
  start_mock MOCK_FEATURES=key-escrow MOCK_TEAM_CIPHER_PROFILE=age-v1
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$(curl -sS "$ENDPOINT/_test/escrow-state" | jq -r '.bundle_gets')" = 0 ]
  [ "$(curl -sS "$ENDPOINT/_test/escrow-state" | jq -r '.registrations')" = 0 ]
}
