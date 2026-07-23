#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  # Start the mock pairing-exchange/revoke server on an OS-assigned port.
  MOCK_REVOKE_FAIL="${MOCK_REVOKE_FAIL:-}" \
  MOCK_REVOKE_BAD_HEADER="${MOCK_REVOKE_BAD_HEADER:-}" \
  MOCK_REVOKE_BAD_BODY="${MOCK_REVOKE_BAD_BODY:-}" \
  MOCK_REVOKE_LARGE_BODY="${MOCK_REVOKE_LARGE_BODY:-}" \
    python3 "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
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

restart_mock_server() {
  kill "$MOCK_SERVER_PID" 2>/dev/null || true
  wait "$MOCK_SERVER_PID" 2>/dev/null || true
  : > "$TEST_SKILL_DIR/server.port"
  MOCK_REVOKE_FAIL="${MOCK_REVOKE_FAIL:-}" \
  MOCK_REVOKE_BAD_HEADER="${MOCK_REVOKE_BAD_HEADER:-}" \
  MOCK_REVOKE_BAD_BODY="${MOCK_REVOKE_BAD_BODY:-}" \
  MOCK_REVOKE_LARGE_BODY="${MOCK_REVOKE_LARGE_BODY:-}" \
    python3 "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
      > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" &
  MOCK_SERVER_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$TEST_SKILL_DIR/server.port" ] && break
    sleep 0.05
  done
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
  mode=$(stat -f '%Lp' "${quarantined[0]}" 2>/dev/null || stat -c '%a' "${quarantined[0]}")
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

# --- dispatch --------------------------------------------------------------

@test "remote.sh: unknown subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/remote.sh" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
