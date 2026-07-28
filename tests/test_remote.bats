#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # Some cases deliberately remove python3 from PATH to verify the control-plane
  # gate. Resolve the fixture interpreter in each test process before that
  # system under test changes its environment.
  MOCK_PYTHON3="$(command -v python3)"
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  # Start the mock pairing-exchange/revoke server on an OS-assigned port.
  MOCK_REVOKE_FAIL="${MOCK_REVOKE_FAIL:-}" \
  MOCK_REVOKE_BAD_HEADER="${MOCK_REVOKE_BAD_HEADER:-}" \
  MOCK_REVOKE_BAD_BODY="${MOCK_REVOKE_BAD_BODY:-}" \
  MOCK_REVOKE_LARGE_BODY="${MOCK_REVOKE_LARGE_BODY:-}" \
    "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_SERVER_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  MOCK_PORT="$(cat "$TEST_SKILL_DIR/server.port")"
  ENDPOINT="http://127.0.0.1:$MOCK_PORT"
}

teardown() {
  kill "$MOCK_SERVER_PID" 2>/dev/null || true
  teardown_test_env
}

restart_mock_server() {
  kill "$MOCK_SERVER_PID" 2>/dev/null || true
  wait "$MOCK_SERVER_PID" 2>/dev/null || true
  : > "$TEST_SKILL_DIR/server.port"
  MOCK_REVOKE_FAIL="${MOCK_REVOKE_FAIL:-}" \
  MOCK_REVOKE_BAD_HEADER="${MOCK_REVOKE_BAD_HEADER:-}" \
  MOCK_REVOKE_BAD_BODY="${MOCK_REVOKE_BAD_BODY:-}" \
  MOCK_REVOKE_LARGE_BODY="${MOCK_REVOKE_LARGE_BODY:-}" \
    "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
      </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_SERVER_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  MOCK_PORT="$(cat "$TEST_SKILL_DIR/server.port")"
  ENDPOINT="http://127.0.0.1:$MOCK_PORT"
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

# --- connect: endpoint/response validation (B6) --------------------------

@test "connect: refuses a non-HTTPS, non-loopback endpoint" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://example.invalid" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be https://"* ]]
}

@test "connect: refuses an endpoint with no scheme at all" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "example.invalid" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must start with https://"* ]]
}

@test "connect: http://127.0.0.1 (loopback) is accepted without https" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  [ "$status" -eq 0 ]
}

@test "connect: requires the response protocol header" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" missing-protocol-header-token myteam
  [ "$status" -ne 0 ]
  [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" wrong-protocol-header-token myteam
  [ "$status" -ne 0 ]
  [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
}

@test "connect: rejects capability limits that differ from the engine validator" {
  for token in max-blob-zero-token max-blob-over-token future-policy-boundary-token; do
    run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" myteam
    [ "$status" -ne 0 ]
    [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
  done
}

@test "connect: bounds response body and header capture before validation" {
  for token in large-body-token large-header-token; do
    run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" myteam
    [ "$status" -ne 0 ]
    [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
  done
}

@test "connect: refuses subdomain-suffix bypass of the loopback exception (127.0.0.1.evil.com)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://127.0.0.1.evil.invalid:${MOCK_PORT}" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be https://"* ]]
}

@test "connect: refuses subdomain-suffix bypass of the loopback exception (localhost.evil.com)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://localhost.evil.invalid:${MOCK_PORT}" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be https://"* ]]
}

@test "connect: refuses the userinfo bypass of the loopback exception (localhost@evil.com)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://localhost@evil.invalid" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"userinfo"* ]]
}

@test "connect: rejects an exchange response with a path-injection-shaped credential_id" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" malformed-credential-id-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid exchange response"* ]]
  # Must not have mutated any local state on the way to rejecting it.
  run bash "$SCRIPTS/remote.sh" status myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"never been connected"* ]]
}

@test "connect: rejects an exchange response missing a required field" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" missing-field-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid exchange response"* ]]
}

@test "connect: rejects an exchange response with a duplicate JSON key (D4)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" duplicate-key-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid exchange response"* ]]
  [[ "$output" == *"duplicate"* ]]
  run bash "$SCRIPTS/remote.sh" status myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"never been connected"* ]]
}

@test "connect: rejects an exchange response with an unrecognized field (D4)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" unknown-field-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid exchange response"* ]]
  [[ "$output" == *"unrecognized"* ]]
}

@test "connect: rejects a credential containing a raw control character (E3)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" control-char-credential-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid exchange response"* ]]
  [[ "$output" == *"control character"* ]]
  run bash "$SCRIPTS/remote.sh" status myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"never been connected"* ]]
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
  perms=$(stat -c "%a" "$SCRIPTS/../run/remote-credentials/myteam.json" 2>/dev/null || stat -f "%Lp" "$SCRIPTS/../run/remote-credentials/myteam.json")
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

@test "connect: --force revokes the OLD credential before establishing the new one (B5)" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token-one myteam
  old_credential_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_binding']['credential_id'])")
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token-two myteam --force
  [ "$status" -eq 0 ]
  new_credential_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_binding']['credential_id'])")
  [ "$old_credential_id" != "$new_credential_id" ]
  revoked=$(curl -s "$ENDPOINT/_test/revoked")
  [[ "$revoked" == *"$old_credential_id"* ]]
}

@test "connect: --force refuses to rebind if the old credential can't be confirmed revoked" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token-one myteam
  # Kill the mock server so revoke can't be reached at all.
  kill "$MOCK_SERVER_PID" 2>/dev/null
  wait "$MOCK_SERVER_PID" 2>/dev/null || true
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token-two myteam --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not confirm the existing credential"* ]]
  # Old binding must still be intact — refusal must not have half-applied.
  run bash "$SCRIPTS/remote.sh" status myteam
  [[ "$output" == *"connected"* ]]
}

@test "connect: --force rejects a 200 revoke body that does not match the binding" {
  MOCK_REVOKE_BAD_BODY=1
  restart_mock_server
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token-one myteam
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token-two myteam --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not confirm the existing credential"* ]]
  run bash "$SCRIPTS/remote.sh" status myteam
  [[ "$output" == *"connected"* ]]
}

@test "connect: --force bounds revoke response before validation" {
  MOCK_REVOKE_LARGE_BODY=1
  restart_mock_server
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token-one myteam
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token-two myteam --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not confirm the existing credential"* ]]
}

@test "connect: --force requires an explicit <team> (refuses when omitted)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"--force requires an explicit"* ]]
}

@test "connect: --force does not blindly overwrite an unexpected binding it never revoked (D1)" {
  # Simulates the race D1 flagged: an exchange already completed (its
  # result sits in a pending record — reachable without --force's own
  # pre-check/revoke step, exactly like a resumed crash-recovery would
  # be) for a credential the team's CURRENT binding was never revoked
  # against. --force must still refuse here rather than treat "force" as
  # an unconditional license to overwrite whatever's there.
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token-one myteam
  current_credential_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_binding']['credential_id'])")

  local token="unrelated-inflight-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  pending_dir="$SCRIPTS/../run/remote-connect-pending"
  mkdir -p "$pending_dir"
  python3 -c "
import json
response = {
    'credential': 'unrelated-credential-value',
    'credential_id': '018f3f7e-5555-7000-8000-000000000005',
    'server_instance_id': '018f3f7e-1111-7000-8000-000000000001',
    'remote_team_id': '018f3f7e-2222-7000-8000-000000000002',
    'remote_team_name': 'myteam',
    'protocol_version': 1,
    'capabilities': {
        'protocol_version': 1,
        'server_instance_id': '018f3f7e-1111-7000-8000-000000000001',
        'team_id': '018f3f7e-2222-7000-8000-000000000002',
        'team_name': 'myteam',
        'accepted_envelope_versions': [1],
        'write_allowed_ciphers': ['none'],
        'policy_revision': '0', 'effective_from_seq': '1',
        'current_seq': '0', 'next_sequence_boundary': '1',
        'min_available_seq': '0', 'max_blob_bytes': '1048576',
        'policy_history': [{
            'policy_revision': '0', 'effective_from_seq': '1',
            'accepted_envelope_versions': [1],
            'write_allowed_ciphers': ['none'],
        }],
    },
}
json.dump({
    'endpoint': '$ENDPOINT',
    'protocol_header_verified': True,
    'raw_response_text': json.dumps(response),
}, open('$pending_dir/$key.json', 'w'))
"
  chmod 600 "$pending_dir/$key.json"

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" myteam --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected binding"* ]]
  # The original binding must be untouched — no silent overwrite.
  after_credential_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_binding']['credential_id'])")
  [ "$after_credential_id" = "$current_credential_id" ]
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

@test "connect: encryption required + empty stream still requires an explicit 'g' to generate" {
  # B3 (adversarial review): local/server "stream empty" signals cannot
  # prove first-writer status (an honest server can show current_seq==0 to
  # two simultaneous devices; a malicious one can fake it to either) — so
  # generate is never an automatic default, empty stream or not. Explicit
  # 'g' still works.
  command -v age >/dev/null 2>&1 || skip "age not installed"
  run bash -c "echo g | bash '$SCRIPTS/remote.sh' connect --endpoint '$ENDPOINT' good-token-enc myteam"
  [ "$status" -eq 0 ]
  [[ "$output" == *"requires end-to-end encryption"* ]]
  [[ "$output" == *"Generated a new key for team 'myteam'"* ]]
  [[ "$output" == *"Connected: team 'myteam'"* ]]
  run bash -c "python3 -c \"import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_key']['current']['key_id'])\""
  [ "$status" -eq 0 ]
}

@test "connect: token stdin remains separate from the E2EE generate prompt" {
  skip_on_windows "PTY-backed secure prompt test requires POSIX controlling-terminal semantics"
  command -v age >/dev/null 2>&1 || skip "age not installed"
  token_file="$(mktemp "$BATS_TEST_TMPDIR/remote-token.XXXXXX")"
  chmod 600 "$token_file"
  printf '%s' 'good-token-enc' > "$token_file"
  run python3 "$BATS_TEST_DIRNAME/helpers/run_remote_connect_tty.py" \
    "$SCRIPTS/remote.sh" "$ENDPOINT" "$token_file" generate
  rm -f "$token_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"requires end-to-end encryption"* ]]
  [[ "$output" == *"Generated a new key for team 'myteam'"* ]]
  [[ "$output" == *"Connected: team 'myteam'"* ]]
  [[ "$output" != *"prefer --token-stdin"* ]]
  [[ "$output" != *"good-token-enc"* ]]
}

@test "connect: encryption required + existing history still requires an explicit 'i' to import" {
  command -v age >/dev/null 2>&1 || skip "age not installed"
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/send.sh" myteam alice alice "seed message so the stream isn't empty" >/dev/null
  identity=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')
  run bash -c "printf 'i\n%s\n' '$identity' | bash '$SCRIPTS/remote.sh' connect --endpoint '$ENDPOINT' good-token-enc myteam"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Imported key for team 'myteam'"* ]]
  [[ "$output" == *"Connected: team 'myteam'"* ]]
}

@test "connect: token stdin remains separate from the E2EE import prompts" {
  skip_on_windows "PTY-backed secure prompt test requires POSIX controlling-terminal semantics"
  command -v age >/dev/null 2>&1 || skip "age not installed"
  identity=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')
  token_file="$(mktemp "$BATS_TEST_TMPDIR/remote-token.XXXXXX")"
  identity_file="$(mktemp "$BATS_TEST_TMPDIR/remote-identity.XXXXXX")"
  chmod 600 "$token_file" "$identity_file"
  printf '%s' 'good-token-enc' > "$token_file"
  printf '%s' "$identity" > "$identity_file"
  run python3 "$BATS_TEST_DIRNAME/helpers/run_remote_connect_tty.py" \
    "$SCRIPTS/remote.sh" "$ENDPOINT" "$token_file" import "$identity_file"
  rm -f "$token_file" "$identity_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Imported key for team 'myteam'"* ]]
  [[ "$output" == *"Connected: team 'myteam'"* ]]
  [[ "$output" != *"prefer --token-stdin"* ]]
  [[ "$output" != *"$identity"* ]]
}

@test "connect: encryption required + empty/EOF input on the choice prompt safely aborts (never auto-generates)" {
  command -v age >/dev/null 2>&1 || skip "age not installed"
  run bash -c "echo | bash '$SCRIPTS/remote.sh' connect --endpoint '$ENDPOINT' good-token-enc myteam"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Generated a new key"* ]]
  run bash -c "python3 -c \"import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json')).get('remote_key'))\""
  [[ "$output" == "None" ]]
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
  for tool in bash sh sqlite3 curl python3 mkdir chmod date mktemp mkfifo rmdir rm cat sed mv grep dirname tr basename env sleep; do
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

# --- connect: pending/resume (B5) -----------------------------------------

@test "connect: quarantines legacy pending recovery material without committing it" {
  local token="legacy-pending-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  pending_dir="$SCRIPTS/../run/remote-connect-pending"
  mkdir -p "$pending_dir"
  printf '%s\n' '{"endpoint":"'$ENDPOINT'","raw_response_text":"{\"credential_id\":\"018f3f7e-8888-7000-8000-000000000008\"}"}' > "$pending_dir/$key.json"
  chmod 600 "$pending_dir/$key.json"

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to resume a legacy pending exchange"* ]]
  [[ "$output" == *"preserved the 0600 recovery record"* ]]
  [ ! -f "$pending_dir/$key.json" ]
  local quarantined=("$pending_dir/$key.json.unverified."*)
  [ "${#quarantined[@]}" -eq 1 ]
  [ -f "${quarantined[0]}" ]
  mode=$(stat -c '%a' "${quarantined[0]}" 2>/dev/null || stat -f '%Lp' "${quarantined[0]}")
  [ "$mode" = "600" ]
  recovered_id=$(python3 -c "import json; p=json.load(open('${quarantined[0]}')); print(json.loads(p['raw_response_text'])['credential_id'])")
  [ "$recovered_id" = "018f3f7e-8888-7000-8000-000000000008" ]
}

@test "connect: resumes from a hand-crafted pending record without a fresh network call" {
  # Simulates the crash-recovery scenario: an exchange already succeeded
  # once (its result was durably saved to the pending file) but the local
  # commit never finished. Re-running `connect` with the SAME
  # (endpoint, token) must complete the commit from the pending record
  # rather than attempting a new exchange — proven here by killing the
  # mock server first: if connect still succeeds, it didn't need the
  # network.
  local token="resume-test-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  pending_dir="$SCRIPTS/../run/remote-connect-pending"
  mkdir -p "$pending_dir"
  python3 -c "
import json
response = {
    'credential': 'resumed-credential-value',
    'credential_id': '018f3f7e-6666-7000-8000-000000000006',
    'server_instance_id': '018f3f7e-3333-7000-8000-000000000003',
    'remote_team_id': '018f3f7e-4444-7000-8000-000000000004',
    'remote_team_name': 'resumedteam',
    'protocol_version': 1,
    'capabilities': {
        'protocol_version': 1,
        'server_instance_id': '018f3f7e-3333-7000-8000-000000000003',
        'team_id': '018f3f7e-4444-7000-8000-000000000004',
        'team_name': 'resumedteam',
        'accepted_envelope_versions': [1],
        'write_allowed_ciphers': ['none'],
        'policy_revision': '0', 'effective_from_seq': '1',
        'current_seq': '0', 'next_sequence_boundary': '1',
        'min_available_seq': '0', 'max_blob_bytes': '1048576',
        'policy_history': [{
            'policy_revision': '0', 'effective_from_seq': '1',
            'accepted_envelope_versions': [1],
            'write_allowed_ciphers': ['none'],
        }],
    },
}
json.dump({
    'endpoint': '$ENDPOINT',
    'protocol_header_verified': True,
    'raw_response_text': json.dumps(response),
}, open('$pending_dir/$key.json', 'w'))
"
  chmod 600 "$pending_dir/$key.json"

  kill "$MOCK_SERVER_PID" 2>/dev/null
  wait "$MOCK_SERVER_PID" 2>/dev/null || true

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" myteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"resuming an exchange"* ]]
  [[ "$output" == *"Connected: team 'myteam'"* ]]
  # Committed content must match the PENDING record's data, not a fresh
  # exchange (there was no live server to get one from).
  credential_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_binding']['credential_id'])")
  [ "$credential_id" = "018f3f7e-6666-7000-8000-000000000006" ]
  # Pending record consumed on success — not left behind.
  [ ! -f "$pending_dir/$key.json" ]
}

@test "connect: resuming after the commit already fully succeeded is an idempotent no-op (R3)" {
  # Simulates a crash AFTER _remote_commit finished but BEFORE the pending
  # file was removed: the binding is already correct, so a retry must not
  # treat its own prior work as a foreign "someone else connected this
  # team" conflict.
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" resume-idempotent-token myteam
  committed_credential_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_binding']['credential_id'])")

  local token="resume-idempotent-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  pending_dir="$SCRIPTS/../run/remote-connect-pending"
  mkdir -p "$pending_dir"
  python3 -c "
import json
response = {
    'credential': 'session-credential-resume-idempotent-token',
    'credential_id': '$committed_credential_id',
    'server_instance_id': '018f3f7e-1111-7000-8000-000000000001',
    'remote_team_id': '018f3f7e-2222-7000-8000-000000000002',
    'remote_team_name': 'myteam',
    'protocol_version': 1,
    'capabilities': {
        'protocol_version': 1,
        'server_instance_id': '018f3f7e-1111-7000-8000-000000000001',
        'team_id': '018f3f7e-2222-7000-8000-000000000002',
        'team_name': 'myteam',
        'accepted_envelope_versions': [1],
        'write_allowed_ciphers': ['none'],
        'policy_revision': '0', 'effective_from_seq': '1',
        'current_seq': '0', 'next_sequence_boundary': '1',
        'min_available_seq': '0', 'max_blob_bytes': '1048576',
        'policy_history': [{
            'policy_revision': '0', 'effective_from_seq': '1',
            'accepted_envelope_versions': [1],
            'write_allowed_ciphers': ['none'],
        }],
    },
}
json.dump({
    'endpoint': '$ENDPOINT',
    'protocol_header_verified': True,
    'raw_response_text': json.dumps(response),
}, open('$pending_dir/$key.json', 'w'))
"
  chmod 600 "$pending_dir/$key.json"

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" myteam
  [ "$status" -eq 0 ]
  [[ "$output" != *"became connected by another process"* ]]
  [ ! -f "$pending_dir/$key.json" ]
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
  MOCK_REVOKE_FAIL=1 "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_SERVER_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  MOCK_PORT="$(cat "$TEST_SKILL_DIR/server.port")"
  ENDPOINT="http://127.0.0.1:$MOCK_PORT"

  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  run bash "$SCRIPTS/remote.sh" disconnect myteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not be reached to revoke"* ]]
  [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
}

@test "disconnect: does not claim revoke success without the protocol response header" {
  MOCK_REVOKE_BAD_HEADER=1
  restart_mock_server
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  run bash "$SCRIPTS/remote.sh" disconnect myteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not be reached to revoke"* ]]
  [[ "$output" != *"Revoking credential with server... ok."* ]]
  [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
}

@test "disconnect: fails for a team that isn't connected" {
  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not connected"* ]]
}

# --- status --json (ADR 0007 addendum) --------------------------------------

@test "status --json: reports the strict schema for an active connection" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  local committed_credential_id
  committed_credential_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_binding']['credential_id'])")
  run bash "$SCRIPTS/remote.sh" status myteam --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.local_team');")" = "myteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.endpoint');")" = "$ENDPOINT" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.credential_id');")" = "$committed_credential_id" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.state');")" = "active" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.server_instance_id');")" != "" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.remote_team_id');")" != "" ]
}

@test "status --json: reports state=disconnected after disconnect" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  local committed_credential_id
  committed_credential_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_binding']['credential_id'])")
  bash "$SCRIPTS/remote.sh" disconnect myteam
  run bash "$SCRIPTS/remote.sh" status myteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.state');")" = "disconnected" ]
  # credential_id from the old binding is still informative, not a live secret.
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.credential_id');")" = "$committed_credential_id" ]
}

@test "status --json: errors for a team that has never been connected" {
  run bash "$SCRIPTS/remote.sh" status ghostteam --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"has never been connected"* ]]
}

@test "status --json: with no <team>, empty output when nothing is connected" {
  run bash "$SCRIPTS/remote.sh" status --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "status --json: with no <team>, emits one JSONL line per connected team" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  bash "$SCRIPTS/join.sh" otherteam bob claude-code /tmp/project-b
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token otherteam
  run bash "$SCRIPTS/remote.sh" status --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  local myteam_line otherteam_line
  myteam_line="$(echo "$output" | grep myteam | grep -v otherteam)"
  otherteam_line="$(echo "$output" | grep otherteam)"
  [ -n "$myteam_line" ]
  [ -n "$otherteam_line" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$myteam_line" | sed "s/'/''/g")', '\$.local_team');")" = "myteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$otherteam_line" | sed "s/'/''/g")', '\$.local_team');")" = "otherteam" ]
}

@test "status: a team name containing a single quote doesn't break status or status --json (#87-class / .param set fix)" {
  local team="o'brien-team"
  bash "$SCRIPTS/join.sh" "$team" carol claude-code /tmp/project-c
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token "$team"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ ".parameter" ]]
  run bash "$SCRIPTS/remote.sh" status "$team"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ ".parameter" ]]
  [[ "$output" == *"connected"* ]]
  run bash "$SCRIPTS/remote.sh" status "$team" --json
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ ".parameter" ]]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.local_team');")" = "$team" ]
}

# --- pending list / abort (ADR 0007 addendum) -------------------------------

_valid_pending_response_json() {
  # A fully-valid exchange response body, matching the shape
  # test_remote.bats's own "resumes from a hand-crafted pending record"
  # test already establishes as this branch's strict-validator baseline.
  local credential_id="$1" server_instance_id="$2" remote_team_id="$3" remote_team_name="$4"
  python3 -c "
import json
response = {
    'credential': 'orphan-test-credential-value',
    'credential_id': '$credential_id',
    'server_instance_id': '$server_instance_id',
    'remote_team_id': '$remote_team_id',
    'remote_team_name': '$remote_team_name',
    'protocol_version': 1,
    'capabilities': {
        'protocol_version': 1,
        'server_instance_id': '$server_instance_id',
        'team_id': '$remote_team_id',
        'team_name': '$remote_team_name',
        'accepted_envelope_versions': [1],
        'write_allowed_ciphers': ['none'],
        'policy_revision': '0', 'effective_from_seq': '1',
        'current_seq': '0', 'next_sequence_boundary': '1',
        'min_available_seq': '0', 'max_blob_bytes': '1048576',
        'policy_history': [{
            'policy_revision': '0', 'effective_from_seq': '1',
            'accepted_envelope_versions': [1],
            'write_allowed_ciphers': ['none'],
        }],
    },
}
print(json.dumps(response))
"
}

_write_pending_record() {
  local key="$1" endpoint="$2" raw_response_text="$3" pending_dir="$4"
  mkdir -p "$pending_dir"
  python3 -c "
import json, sys
raw = sys.stdin.read()
json.dump({'endpoint': '$endpoint', 'protocol_header_verified': True, 'raw_response_text': raw},
          open('$pending_dir/$key.json', 'w'))
" <<< "$raw_response_text"
}

@test "pending list: reports nothing when there are no pending records" {
  run bash "$SCRIPTS/remote.sh" pending list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pending connect records"* ]]
  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pending list: does not list a record that already fully committed" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" good-token myteam
  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pending list --json: reports a valid orphaned record with its metadata, no credential" {
  local token="orphan-test-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  local resp
  resp=$(_valid_pending_response_json \
    "018f3f7e-6666-7000-8000-000000000006" \
    "018f3f7e-3333-7000-8000-000000000003" \
    "018f3f7e-4444-7000-8000-000000000004" \
    "orphanteam")
  _write_pending_record "$key" "$ENDPOINT" "$resp" "$pending_dir"

  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  local escaped; escaped="$(echo "$output" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.pending_id');")" = "$key" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.endpoint');")" = "$ENDPOINT" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.credential_id');")" = "018f3f7e-6666-7000-8000-000000000006" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.valid');")" = "1" ]
  # The raw credential must never appear anywhere in the listing output.
  [[ "$output" != *"orphan-test-credential-value"* ]]
}

@test "pending list --json: reports valid:false and null metadata for a record whose content fails validation" {
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  local key; key="$(printf 'a%.0s' $(seq 1 64))"
  _write_pending_record "$key" "$ENDPOINT" '{not valid json' "$pending_dir"

  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  local escaped; escaped="$(echo "$output" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.pending_id');")" = "$key" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.endpoint');")" = "$ENDPOINT" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.valid');")" = "0" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.credential_id');")" = "" ]
}

@test "pending list --json: still reports pending_id even when the envelope itself is corrupt" {
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  mkdir -p "$pending_dir"
  local key; key="$(printf 'b%.0s' $(seq 1 64))"
  printf 'not even json' > "$pending_dir/$key.json"

  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  local escaped; escaped="$(echo "$output" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.pending_id');")" = "$key" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.endpoint');")" = "" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.valid');")" = "0" ]
}

@test "pending list --json: does not enumerate a quarantined record (only normal <id>.json files)" {
  local token="quarantine-visibility-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  # Legacy 2-key envelope (no protocol_header_verified) — triggers
  # cmd_connect's own quarantine path on resume, exercised here directly by
  # hand-crafting the pre-quarantine legacy file and quarantining it the
  # same way cmd_connect would.
  mkdir -p "$pending_dir"
  python3 -c "
import json
json.dump({'endpoint': '$ENDPOINT', 'raw_response_text': '{}'}, open('$pending_dir/$key.json', 'w'))
"
  mv "$pending_dir/$key.json" "$pending_dir/$key.json.unverified.20260101T000000Z.1"

  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$SCRIPTS/remote.sh" pending list
  [[ "$output" == *"No pending connect records"* ]]
}

@test "pending abort: rejects a malformed pending_id" {
  run bash "$SCRIPTS/remote.sh" pending abort "not-a-valid-id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid pending_id"* ]]
  run bash "$SCRIPTS/remote.sh" pending abort "../../escape"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid pending_id"* ]]
}

@test "pending abort: removes a valid pending record" {
  local token="abort-test-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  _write_pending_record "$key" "$ENDPOINT" '{}' "$pending_dir"

  run bash "$SCRIPTS/remote.sh" pending abort "$key"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted pending connect record $key"* ]]
  [ ! -f "$pending_dir/$key.json" ]
}

@test "pending abort: fails clearly for an unknown pending_id" {
  local key; key="$(printf 'c%.0s' $(seq 1 64))"
  run bash "$SCRIPTS/remote.sh" pending abort "$key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no pending connect record"* ]]
}

@test "pending abort: aborting the same pending_id twice is not silently treated as success" {
  local token="double-abort-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  _write_pending_record "$key" "$ENDPOINT" '{}' "$pending_dir"

  bash "$SCRIPTS/remote.sh" pending abort "$key"
  run bash "$SCRIPTS/remote.sh" pending abort "$key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no pending connect record"* ]]
}

# --- pending/connect lock barrier (co1 delta review) ------------------------
#
# Deterministic, single-threaded simulation of the race co1 flagged (see
# feat/remote-connect-onboarding's PR #479): rather than actually racing two
# live processes, pre-insert a row in the runtime `locks` table matching
# exactly what `_remote_pending_lock_acquire` would have written, then
# assert the OTHER operation either blocks (live owner) or reclaims (dead
# owner) as appropriate. AGMSG_PENDING_LOCK_TRIES keeps the timeout fast.

_insert_pending_lock_row() {
  local key="$1" owner_pid="$2" db="$SCRIPTS/../db/messages.db"
  sqlite3 "$db" "
CREATE TABLE IF NOT EXISTS locks (
  resource TEXT PRIMARY KEY,
  owner_pid INTEGER NOT NULL,
  acquired_at TEXT NOT NULL
);
INSERT OR REPLACE INTO locks(resource, owner_pid, acquired_at)
VALUES ('remote-pending.$key', $owner_pid, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
"
}

@test "pending abort: blocks (not deletes) when a concurrent connect resume already holds this pending_id's lock (barrier test)" {
  local token="lock-barrier-abort-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  _write_pending_record "$key" "$ENDPOINT" '{}' "$pending_dir"
  _insert_pending_lock_row "$key" "$$"

  AGMSG_PENDING_LOCK_TRIES=3 run bash "$SCRIPTS/remote.sh" pending abort "$key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out acquiring pending lock"* ]]
  [ -f "$pending_dir/$key.json" ]
}

@test "connect: blocks (does not resume/commit) when a concurrent pending abort already holds this pending_id's lock (barrier test)" {
  local token="lock-barrier-connect-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  local resp
  resp=$(_valid_pending_response_json \
    "018f3f7e-9999-7000-8000-000000000009" \
    "018f3f7e-3333-7000-8000-000000000003" \
    "018f3f7e-4444-7000-8000-000000000004" \
    "barrierteam")
  _write_pending_record "$key" "$ENDPOINT" "$resp" "$pending_dir"
  _insert_pending_lock_row "$key" "$$"

  AGMSG_PENDING_LOCK_TRIES=3 run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" barrierteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out acquiring pending lock"* ]]
  [ ! -f "$SCRIPTS/../teams/barrierteam/config.json" ]
  [ -f "$pending_dir/$key.json" ]
}

@test "pending abort: reclaims a stale lock left by a dead owner instead of blocking forever (barrier test)" {
  local token="lock-barrier-stale-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  _write_pending_record "$key" "$ENDPOINT" '{}' "$pending_dir"

  ( : ) &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  _insert_pending_lock_row "$key" "$dead_pid"

  AGMSG_PENDING_LOCK_TRIES=20 run bash "$SCRIPTS/remote.sh" pending abort "$key"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted pending connect record $key"* ]]
  [ ! -f "$pending_dir/$key.json" ]
}

@test "remote.sh: unknown pending subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/remote.sh" pending bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- dispatch --------------------------------------------------------------

@test "remote.sh: unknown subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/remote.sh" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- python3 preflight (dependency tiering: remote = +python3) -------------

@test "remote status: fails fast with an install message when python3 is absent, never hangs" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
  [[ "$output" == *"brew install python3"* ]]
}

@test "remote connect: fails fast with an install message when python3 is absent" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" connect testteam https://example.invalid tok
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
}

@test "remote disconnect: fails fast with an install message when python3 is absent" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
}

@test "remote pending: fails fast with an install message when python3 is absent" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" pending list
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
}

@test "remote doctor: still runs without python3, and reports it as a failed check (not a crash)" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ ] python3 on PATH"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "remote doctor: reports python3 as present when it is available" {
  run bash "$SCRIPTS/remote.sh" doctor
  [[ "$output" == *"[x] python3 on PATH"* ]]
}

# --- co1 delta review P1: doctor must also check node (sync data plane) ----
# Node is a SEPARATE, independent dependency from python3 (remote sync data
# plane vs. remote control plane) -- doctor claiming "All checks passed"
# with age+python3 present but node missing would contradict reality, since
# remote-sync.sh cannot run without node.

@test "remote doctor: reports node as a failed check (not silently ignored) when unusable, and does not claim overall success" {
  run env AGMSG_NODE=/definitely/does/not/exist/node bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ ] node on PATH"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "remote doctor: reports node as present when it resolves to a usable binary" {
  run bash "$SCRIPTS/remote.sh" doctor
  [[ "$output" == *"[x] node on PATH"* ]]
}

@test "remote doctor: passes overall only when age, python3, AND node are all usable" {
  command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 \
    && command -v python3 >/dev/null 2>&1 && command -v node >/dev/null 2>&1 \
    || skip "all doctor prerequisites are not installed"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed."* ]]
}

PULL_TEAM_ID=018f3f7e-2222-7000-8000-000000000002

@test "remote pull: clones a team, keeping the id the server gave" {
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  local cfg
  cfg="$TEST_SKILL_DIR/teams/cloned/config.json"
  [ -f "$cfg" ]
  # Not minted here: the id is the one the server answered with.
  [ "$(sqlite_mem "SELECT json_extract(readfile('$(rf "$cfg")'), '\$.team_id');")" = "$PULL_TEAM_ID" ]
}

@test "remote pull: does not take a roster from the server" {
  # The server holds no membership -- it travels inside the envelope, so under
  # e2ee the server cannot read it. A roster invented here would be a guess
  # presented as fact; it is derived by replaying the team journal instead.
  #
  # The mock deliberately still answers with a members array, so this fails if
  # the client starts trusting one again rather than merely because none was
  # offered.
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  local cfg agents
  cfg="$TEST_SKILL_DIR/teams/cloned/config.json"
  agents="$(sqlite_mem "SELECT json_extract(readfile('$(rf "$cfg")'), '\$.agents');")"
  [ "$agents" = "{}" ]
}

@test "remote pull: refuses a team that already has history" {
  bash "$SCRIPTS/join.sh" occupied alice claude-code /tmp/project-b >/dev/null
  bash "$SCRIPTS/send.sh" occupied alice alice "already mine" >/dev/null
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" occupied
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has history"* ]]
}

@test "remote pull: requires an endpoint, a team id and a local name" {
  run bash "$SCRIPTS/remote.sh" pull --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -ne 0 ]
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -ne 0 ]
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID"
  [ "$status" -ne 0 ]
}

@test "remote pull: the cloned team can be read with the ordinary commands" {
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  # The point of the whole step: the history is here, not just the team.
  [[ "$output" == *"2 message(s)"* ]]
  run bash "$SCRIPTS/history.sh" cloned alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"history one"* ]]
  [[ "$output" == *"history two"* ]]
}
