#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  # Start the mock pairing-exchange/revoke server on an OS-assigned port.
  MOCK_REVOKE_FAIL="${MOCK_REVOKE_FAIL:-}" python3 "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" &
  MOCK_SERVER_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$TEST_SKILL_DIR/server.port" ] && break
    sleep 0.05
  done
  MOCK_PORT="$(cat "$TEST_SKILL_DIR/server.port")"
  ENDPOINT="http://127.0.0.1:$MOCK_PORT"
}

teardown() {
  kill "$MOCK_SERVER_PID" 2>/dev/null || true
  teardown_test_env
}

# --- doctor ------------------------------------------------------------

@test "remote doctor: passes when age is installed" {
  command -v age >/dev/null 2>&1 || skip "age not installed"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"age / age-keygen on PATH"* ]]
  [[ "$output" == *"All checks passed."* ]]
}

@test "remote doctor: is read-only (no token required, no state touched)" {
  run bash "$SCRIPTS/remote.sh" doctor testteam
  run grep -c "remote_binding" "$SCRIPTS/../teams/testteam/config.json"
  [ "$output" -eq 0 ]
}

# --- connect -------------------------------------------------------------

@test "connect: happy path, no encryption required" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connected: team 'myteam'"* ]]
  [ -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
}

@test "connect: credential file is 0600 and never appears in team config.json" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  perms=$(stat -f "%Lp" "$SCRIPTS/../run/remote-credentials/myteam.json" 2>/dev/null || stat -c "%a" "$SCRIPTS/../run/remote-credentials/myteam.json")
  [ "$perms" = "600" ]
  run grep -c "session-credential" "$SCRIPTS/../teams/myteam/config.json"
  [ "$output" -eq 0 ]
}

@test "connect: bare positional token warns on stderr; --token-stdin does not" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  [[ "$output" == *"prefer --token-stdin"* ]]
  bash "$SCRIPTS/remote.sh" disconnect myteam >/dev/null
  run bash -c "printf 'good-token' | bash '$SCRIPTS/remote.sh' connect --endpoint '$ENDPOINT' --token-stdin myteam"
  [ "$status" -eq 0 ]
  [[ "$output" != *"prefer --token-stdin"* ]]
}

@test "connect: bad token surfaces the exchange endpoint's HTTP error" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" bad-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 401"* ]]
}

@test "connect: refuses to rebind an already-connected team without --force" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"already connected"* ]]
  [[ "$output" == *"--force"* ]]
}

@test "connect: --force allows rebinding an already-connected team" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam --force
  [ "$status" -eq 0 ]
}

@test "connect: after disconnect, reconnecting the same team needs no --force" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  bash "$SCRIPTS/remote.sh" disconnect myteam
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  [ "$status" -eq 0 ]
}

@test "connect: uses the exchange response's remote_team_name when <team> is omitted" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token
  [ "$status" -eq 0 ]
  [ -f "$SCRIPTS/../teams/myteam/config.json" ]
}

@test "connect: encryption required + empty stream defaults to generate" {
  # read -p's prompt text is only ever shown on a real TTY (bash suppresses
  # it entirely when stdin is piped, as it is here) — so this asserts the
  # FUNCTIONAL result of accepting the default (a key gets generated), not
  # the literal prompt string, which piped stdin never surfaces either way.
  command -v age >/dev/null 2>&1 || skip "age not installed"
  run bash -c "echo | bash '$SCRIPTS/remote.sh' connect --endpoint '$ENDPOINT' good-token-enc myteam"
  [ "$status" -eq 0 ]
  [[ "$output" == *"requires end-to-end encryption"* ]]
  [[ "$output" == *"Generated a new key for team 'myteam'"* ]]
  [[ "$output" == *"Connected: team 'myteam'"* ]]
  run bash -c "python3 -c \"import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_key']['current']['key_id'])\""
  [ "$status" -eq 0 ]
}

@test "connect: encryption required + existing history defaults to import" {
  command -v age >/dev/null 2>&1 || skip "age not installed"
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/send.sh" myteam alice alice "seed message so the stream isn't empty" >/dev/null
  identity=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')
  # Empty input (just Enter) accepts the default, which must be "import"
  # here — feeding no explicit "i" isolates that the default itself picked
  # import, not that we forced it.
  run bash -c "printf '\n%s\n' '$identity' | bash '$SCRIPTS/remote.sh' connect --endpoint '$ENDPOINT' good-token-enc myteam"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Imported key for team 'myteam'"* ]]
  [[ "$output" == *"Connected: team 'myteam'"* ]]
}

@test "connect: aborting the encryption prompt leaves the binding but no key, visible via status" {
  command -v age >/dev/null 2>&1 || skip "age not installed"
  run bash -c "echo a | bash '$SCRIPTS/remote.sh' connect --endpoint '$ENDPOINT' good-token-enc myteam"
  [ "$status" -ne 0 ]
  run bash "$SCRIPTS/remote.sh" status myteam
  [[ "$output" == *"no local key"* ]]
}

@test "connect: missing age binary blocks the encryption bootstrap with an install hint" {
  # Build a PATH containing everything connect's call chain needs EXCEPT
  # age/age-keygen, so the absence check is exercised for real rather than
  # by replacing all of $PATH (which would also break curl/python3/sqlite3
  # and make this fail for the wrong reason).
  fakebin=$(mktemp -d)
  for tool in bash sh sqlite3 curl python3 mkdir chmod date mktemp rm cat sed mv grep dirname tr basename env sleep; do
    p="$(command -v "$tool" 2>/dev/null)" && ln -s "$p" "$fakebin/$tool"
  done
  run bash -c "PATH='$fakebin' bash '$SCRIPTS/remote.sh' connect --endpoint '$ENDPOINT' good-token-enc myteam"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'age' is required"* ]]
  [[ "$output" == *"brew install age"* ]]
}

# --- status --------------------------------------------------------------

@test "status: reports 'never connected' for an unknown team" {
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"never been connected"* ]]
}

@test "status: with no <team> lists every locally-known connected team" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  bash "$SCRIPTS/join.sh" secondteam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token secondteam --force >/dev/null
  run bash "$SCRIPTS/remote.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"myteam"* ]]
  [[ "$output" == *"secondteam"* ]]
}

# --- disconnect ------------------------------------------------------------

@test "disconnect: revokes server-side then clears local state" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  run bash "$SCRIPTS/remote.sh" disconnect myteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Revoking credential with server... ok."* ]]
  [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
  run bash "$SCRIPTS/remote.sh" status myteam
  [[ "$output" == *"was connected until"* ]]
}

@test "disconnect: server unreachable for revoke still clears local state, with a warning" {
  MOCK_REVOKE_FAIL=1
  kill "$MOCK_SERVER_PID" 2>/dev/null
  MOCK_REVOKE_FAIL=1 python3 "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" &
  MOCK_SERVER_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$TEST_SKILL_DIR/server.port" ] && break
    sleep 0.05
  done
  MOCK_PORT="$(cat "$TEST_SKILL_DIR/server.port")"
  ENDPOINT="http://127.0.0.1:$MOCK_PORT"

  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  run bash "$SCRIPTS/remote.sh" disconnect myteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not be reached to revoke"* ]]
  [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
}

@test "disconnect: fails for a team that isn't connected" {
  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not connected"* ]]
}

# --- dispatch --------------------------------------------------------------

@test "remote.sh: unknown subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/remote.sh" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
