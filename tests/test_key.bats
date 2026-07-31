#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-a
}

teardown() {
  teardown_test_env
}

# key.sh needs the real `age`/`age-keygen` binaries — skip
# gracefully rather than failing when they're not installed on the runner.
skip_if_no_age() {
  command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 || skip "age/age-keygen not installed"
}

bind_testteam() {
  local config="$SCRIPTS/../teams/testteam/config.json"
  python3 -c "
import json
p = '$config'
d = json.load(open(p))
d['remote_binding'] = {
  'endpoint': 'https://sync.example.test',
  'server_instance_id': '018f3f7e-0000-7000-8000-000000000000',
  'remote_team_id': d['team_id'],
  'remote_team_name': d['name'],
  'protocol_version': 1,
  'capabilities': {'write_allowed_ciphers': ['none', 'age-v1']},
  'connected_at': '2026-07-30T00:00:00Z',
  'disconnected_at': None,
}
open(p, 'w').write(json.dumps(d) + '\\n')
"
}

stub_current_age_snapshot() {
  cat > "$SCRIPTS/remote-sync.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "export-age-snapshot" ]
shift
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ]
printf '%s' '{"epoch_revision":"0"}' > "$out"
EOF
  chmod +x "$SCRIPTS/remote-sync.sh"
}

stub_age_handoff() {
  cat > "$SCRIPTS/remote-sync.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "export-age-handoff" ]
shift
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ]
printf '%s' '{"format_version":1,"identities":[],"snapshots":[],"type":"agmsg_age_v1_handoff"}' > "$out"
chmod 600 "$out"
echo "Snapshot SHA-256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >&2
EOF
  chmod +x "$SCRIPTS/remote-sync.sh"
}

# --- generate --------------------------------------------------------------

@test "key generate: creates a first epoch and prints the backup notice" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated a new key for team 'testteam'"* ]]
  [[ "$output" == *"Recipient fingerprint:"* ]]
  [[ "$output" == *"Back this up now"* ]]
  [[ "$output" == *"no server-side recovery"* ]]
}

@test "key generate: stores public recipient (not secret) in team config" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  run bash -c "python3 -c \"import json; d=json.load(open('$SCRIPTS/../teams/testteam/config.json')); print(d['remote_key']['current']['recipient'])\""
  [ "$status" -eq 0 ]
  [[ "$output" == age1* ]]
}

@test "key generate: private identity file is 0600 and not inside config.json" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  key_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['current']['key_id'])")
  identity_file="$SCRIPTS/../run/remote-credentials/testteam/keys/$key_id.key"
  [ -f "$identity_file" ]
  perms=$(stat -f "%Lp" "$identity_file" 2>/dev/null || stat -c "%a" "$identity_file")
  [ "$perms" = "600" ]
  run grep -c "AGE-SECRET-KEY" "$SCRIPTS/../teams/testteam/config.json"
  [ "$output" -eq 0 ]
}

@test "key generate: refuses to run twice for the same team" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has a key"* ]]
}

@test "key generate: fails for an unknown team" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" generate notateam
  [ "$status" -ne 0 ]
  [[ "$output" == *"team not found"* ]]
}

@test "key generate: rejects a path-traversal team name" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" generate "../escape"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid team name"* ]]
}

@test "key generate refuses to turn a connected plaintext history into E2EE" {
  bind_testteam
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"plaintext remote binding"* ]]
  [[ "$output" == *"cannot be changed later"* ]]
  [[ "$output" == *"Create a new team"* ]]
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$SCRIPTS/../teams/testteam/config.json")') AS TEXT), '\$.remote_key.current.key_id');")" = "" ]
}

# --- show --------------------------------------------------------------

@test "key show: default prints only public recipient and fingerprint" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  run bash "$SCRIPTS/key.sh" show testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recipient fingerprint:"* ]]
  [[ "$output" == *"Public recipient: age1"* ]]
  [[ "$output" != *"AGE-SECRET-KEY"* ]]
}

@test "key show: fails when the team has no key yet" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" show testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no key yet"* ]]
}

@test "key show --reveal-secret: refused without a TTY (agent mode)" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  run bash "$SCRIPTS/key.sh" show testteam --reveal-secret
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused in agent mode"* ]]
  [[ "$output" != *"AGE-SECRET-KEY"* ]]
}

@test "key show --snapshot exports stable compact JCS and lowercase digest" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  config="$SCRIPTS/../teams/testteam/config.json"
  bind_testteam
  first="$TEST_SKILL_DIR/first-snapshot.json"
  second="$TEST_SKILL_DIR/second-snapshot.json"

  run bash "$SCRIPTS/key.sh" show testteam --snapshot --out "$first"
  [ "$status" -eq 0 ]
  first_output="$output"
  [[ "$first_output" =~ Snapshot\ SHA-256:\ [0-9a-f]{64} ]]
  run bash "$SCRIPTS/key.sh" show testteam --snapshot --out "$second"
  [ "$status" -eq 0 ]
  [ "$output" = "$first_output" ]
  cmp "$first" "$second"
  [ "$(wc -l < "$first" | tr -d ' ')" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_valid(CAST(readfile('$(rf "$first")') AS TEXT));")" = "1" ]
  key_id="$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$config")') AS TEXT), '\$.remote_key.current.key_id');")"
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$first")') AS TEXT), '\$.authorized_writers[0]');")" = "$key_id" ]
}

@test "key handoff writes a secret bundle and prints its digest and warning" {
  skip_if_no_age
  stub_age_handoff
  local bundle="$TEST_SKILL_DIR/handoff.json"
  run bash "$SCRIPTS/key.sh" handoff testteam --out "$bundle"
  [ "$status" -eq 0 ]
  [ -f "$bundle" ]
  [[ "$output" == *"Snapshot SHA-256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"* ]]
  [[ "$output" == *"KEEP SECRET — this file IS the key"* ]]
  [[ "$output" == *"Handoff bundle written to: $bundle"* ]]
}

@test "key handoff without --out never writes the secret bundle under cwd" {
  skip_if_no_age
  stub_age_handoff
  local project="$TEST_SKILL_DIR/project-checkout"
  mkdir -p "$project"
  cd "$project"
  run bash "$SCRIPTS/key.sh" handoff testteam
  [ "$status" -eq 0 ]
  [ ! -e "$project/testteam-age-handoff.json" ]
  local private_bundle="$TEST_SKILL_DIR/run/remote-credentials/testteam/handoff/testteam-age-handoff.json"
  [ -f "$private_bundle" ]
  [[ "$output" == *"Handoff bundle written to: $private_bundle"* ]]
  local perms
  perms=$(stat -f "%Lp" "$(dirname "$private_bundle")" 2>/dev/null || stat -c "%a" "$(dirname "$private_bundle")")
  [ "$perms" = "700" ]
}

# --- import --------------------------------------------------------------

@test "key import --identity-stdin: establishes the first epoch for a team with no key yet" {
  skip_if_no_age
  secret=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --identity-stdin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Imported key for team 'testteam'"* ]]
}

@test "key import --key-id: preserves the authority key id and is idempotent" {
  skip_if_no_age
  secret=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --key-id epoch-handed --identity-stdin"
  [ "$status" -eq 0 ]
  config="$SCRIPTS/../teams/testteam/config.json"
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$config")') AS TEXT), '\$.remote_key.current.key_id');")" = "epoch-handed" ]
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --key-id epoch-handed --identity-stdin"
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_array_length(json_extract(CAST(readfile('$(rf "$config")') AS TEXT), '\$.remote_key.epochs'));")" -eq 1 ]
}

@test "key import: legacy positional identity warns on stderr; --identity-stdin does not" {
  skip_if_no_age
  secret=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')
  run bash "$SCRIPTS/key.sh" import testteam "$secret"
  [[ "$output" == *"prefer --identity-stdin"* ]]
  bash "$SCRIPTS/key.sh" import testteam "$secret" >/dev/null
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --identity-stdin"
  [[ "$output" != *"prefer --identity-stdin"* ]]
}

@test "key import: matching identity for an already-keyed team succeeds without a new epoch" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  key_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['current']['key_id'])")
  secret=$(grep '^AGE-SECRET-KEY-' "$SCRIPTS/../run/remote-credentials/testteam/keys/$key_id.key")
  before=$(python3 -c "import json; print(len(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['epochs']))")
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --identity-stdin"
  [ "$status" -eq 0 ]
  after=$(python3 -c "import json; print(len(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['epochs']))")
  [ "$before" = "$after" ]
}

@test "key import: identity file is still valid and intact after a re-import (atomic write, no truncation)" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  key_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['current']['key_id'])")
  identity_file="$SCRIPTS/../run/remote-credentials/testteam/keys/$key_id.key"
  secret=$(grep '^AGE-SECRET-KEY-' "$identity_file")
  # Re-import the SAME identity. The write goes through a temp file (0600,
  # never colliding, never following a symlink at the destination) + atomic
  # rename — the real path is never truncated in place, so a crash mid-write
  # can't leave it half-written. The file's own comment header is expected
  # to differ (re-import only ever has the bare secret to write), but the
  # secret itself, and a fresh age-keygen -y round-trip against it, must
  # still be intact and valid.
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --identity-stdin"
  [ "$status" -eq 0 ]
  [ -f "$identity_file" ]
  perms=$(stat -f "%Lp" "$identity_file" 2>/dev/null || stat -c "%a" "$identity_file")
  [ "$perms" = "600" ]
  run bash -c "age-keygen -y < '$identity_file'"
  [ "$status" -eq 0 ]
  [[ "$output" == age1* ]]
}

@test "key import: mismatched identity for an already-keyed team is rejected (fail closed)" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  other_secret=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')
  run bash -c "printf '%s' '$other_secret' | bash '$SCRIPTS/key.sh' import testteam --identity-stdin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
}

@test "key import: rejects a malformed identity string" {
  skip_if_no_age
  run bash -c "printf 'not-a-real-identity' | bash '$SCRIPTS/key.sh' import testteam --identity-stdin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a well-formed age identity"* ]]
}

@test "key generate: concurrent calls for the same never-before-keyed team don't both mint an epoch" {
  skip_if_no_age
  local gen1_out gen2_out
  gen1_out="$(mktemp)"
  gen2_out="$(mktemp)"
  bash "$SCRIPTS/key.sh" generate testteam >"$gen1_out" 2>&1 &
  p1=$!
  bash "$SCRIPTS/key.sh" generate testteam >"$gen2_out" 2>&1 &
  p2=$!
  # `wait` returns the backgrounded job's own exit status, and one of these
  # two is SUPPOSED to fail (exactly one racer wins) — under bats' implicit
  # `set -e`, a bare `wait` returning non-zero would abort the test right
  # here, so capture with `|| s=$?` instead of asserting on `wait` itself.
  s1=0; wait "$p1" || s1=$?
  s2=0; wait "$p2" || s2=$?
  rm -f "$gen1_out" "$gen2_out"
  # Exactly one succeeds, the other sees "already has a key" — never two
  # successes (which would mean two unrelated epoch-0 keys got minted).
  successes=0
  [ "$s1" -eq 0 ] && successes=$((successes + 1))
  [ "$s2" -eq 0 ] && successes=$((successes + 1))
  [ "$successes" -eq 1 ]
  epochs=$(python3 -c "import json; print(len(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['epochs']))")
  [ "$epochs" -eq 1 ]
}

# --- rotate ---------------------------------------------------------------

@test "key rotate: creates a replacement identity and journals only its fingerprint" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  stub_current_age_snapshot
  run bash "$SCRIPTS/key.sh" rotate testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated replacement key"* ]]
  journal="$SCRIPTS/../teams/testteam/roster.jsonl"
  epoch=$(python3 -c "import json; print([json.loads(x) for x in open('$journal') if json.loads(x).get('type') == 'key_rotated'][-1]['epoch'])")
  key_id=$(python3 -c "import json; print([json.loads(x) for x in open('$journal') if json.loads(x).get('type') == 'key_rotated'][-1]['key_id'])")
  fingerprint=$(python3 -c "import json; print([json.loads(x) for x in open('$journal') if json.loads(x).get('type') == 'key_rotated'][-1]['fingerprint'])")
  [ "$epoch" = "1" ]
  [[ "$key_id" == epoch-* ]]
  [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]]
  [ -f "$SCRIPTS/../run/remote-credentials/testteam/keys/$key_id.key" ]
  [ "$(python3 -c "import json; d=json.load(open('$SCRIPTS/../teams/testteam/config.json')); print(d['remote_key']['current']['key_id'])")" = "$key_id" ]
  [ "$(python3 -c "import json; d=json.load(open('$SCRIPTS/../teams/testteam/config.json')); print(len(d['remote_key']['epochs']))")" -eq 2 ]
  ! grep -q 'AGE-SECRET-KEY\\|age1' "$journal"
  run bash "$SCRIPTS/key.sh" show testteam --key-id "$key_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Public recipient: age1"* ]]
}

@test "key rotate: an old identity cannot decrypt data for the replacement epoch" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  stub_current_age_snapshot
  old_epoch=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['current']['key_id'])")
  old_identity="$SCRIPTS/../run/remote-credentials/testteam/keys/$old_epoch.key"
  bash "$SCRIPTS/key.sh" rotate testteam
  journal="$SCRIPTS/../teams/testteam/roster.jsonl"
  new_key_id=$(python3 -c "import json; print([json.loads(x) for x in open('$journal') if json.loads(x).get('type') == 'key_rotated'][-1]['key_id'])")
  new_identity="$SCRIPTS/../run/remote-credentials/testteam/keys/$new_key_id.key"
  new_recipient=$(age-keygen -y "$new_identity")
  ciphertext="$TEST_SKILL_DIR/replacement.age"
  printf 'future message' | age -r "$new_recipient" -o "$ciphertext"
  run age -d -i "$old_identity" "$ciphertext"
  [ "$status" -ne 0 ]
  [[ "$output" != *"future message"* ]]
}

@test "key import: installs an out-of-band replacement only after its fingerprint is announced" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  stub_current_age_snapshot
  bash "$SCRIPTS/key.sh" rotate testteam
  journal="$SCRIPTS/../teams/testteam/roster.jsonl"
  key_id=$(python3 -c "import json; print([json.loads(x) for x in open('$journal') if json.loads(x).get('type') == 'key_rotated'][-1]['key_id'])")
  identity="$SCRIPTS/../run/remote-credentials/testteam/keys/$key_id.key"
  secret=$(grep '^AGE-SECRET-KEY-' "$identity")
  rm -f "$identity"
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --key-id wrong-announced-id --identity-stdin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match the announced rotation"* ]]
  [ ! -f "$identity" ]
  [ ! -f "$SCRIPTS/../run/remote-credentials/testteam/keys/wrong-announced-id.key" ]

  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --key-id '$key_id' --identity-stdin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Imported replacement key"* ]]
  [ -f "$identity" ]
}

@test "key import: rejects an authority key id absent from announced rotations" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  secret=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')

  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --key-id epoch-unannounced --identity-stdin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match the current key or an announced rotation"* ]]
  [ ! -f "$SCRIPTS/../run/remote-credentials/testteam/keys/epoch-unannounced.key" ]
}

@test "key rotate: advances the shared epoch only after the previous winner is synchronized" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  stub_current_age_snapshot
  config="$SCRIPTS/../teams/testteam/config.json"
  journal="$SCRIPTS/../teams/testteam/roster.jsonl"
  server_id="018f3f7e-0000-7000-8000-000000000000"
  team_id="018f3f7e-0000-7000-8000-000000000001"
  python3 -c "import json; p='$config'; d=json.load(open(p)); d['remote_binding']={'server_instance_id':'$server_id','remote_team_id':'$team_id'}; open(p,'w').write(json.dumps(d)+'\n')"
  bash "$SCRIPTS/key.sh" rotate testteam
  mutation_id=$(python3 -c "import json; print([json.loads(x) for x in open('$journal') if json.loads(x).get('type') == 'key_rotated'][-1]['id'])")
  printf '%s\n' "{\"type\":\"roster_synced\",\"mutation_id\":\"$mutation_id\",\"server_seq\":\"8\",\"wire_id\":\"550e8400-e29b-41d4-a716-446655440006\",\"server_instance_id\":\"$server_id\",\"remote_team_id\":\"$team_id\"}" >> "$journal"
  run bash "$SCRIPTS/key.sh" rotate testteam
  [ "$status" -eq 0 ]
  latest_epoch=$(python3 -c "import json; print([json.loads(x) for x in open('$journal') if json.loads(x).get('type') == 'key_rotated'][-1]['epoch'])")
  [ "$latest_epoch" = "2" ]
}

@test "key rotate: refuses a team with no current key" {
  run bash "$SCRIPTS/key.sh" rotate testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"no current key"* ]]
}

# --- dispatch --------------------------------------------------------------

@test "key.sh: unknown subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/key.sh" bogus testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
