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

# $1 = the epoch revision the authority has confirmed (default 0, i.e. nothing
# rotated yet has been sequenced). $2/$3 = the key_id and recipient it sequenced.
# The chain's tail names the WINNER, not just the revision: competing rotations
# share a revision and the authority picks one, so a test that wants a rotation
# confirmed has to say which one.
stub_current_age_snapshot() {
  local revision="${1:-0}" key_id="${2:-}" recipient="${3:-}" history=""
  if [ -n "$key_id" ]; then
    history=",\"history\":[{\"epoch_revision\":\"${revision}\",\"key_id\":\"${key_id}\",\"recipients\":[\"${recipient}\"]}]"
  fi
  cat > "$SCRIPTS/remote-sync.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\$1" = "export-age-snapshot" ]
shift
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --out) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$out" ]
printf '%s' '{"epoch_revision":"${revision}"${history}}' > "\$out"
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
  # The facts ride along with it, and are asserted here too so the split
  # between fact and guidance cannot quietly move.
  [[ "$output" == *"no copy of it survives anywhere"* ]]
  [[ "$output" == *"becomes permanently unreadable"* ]]
  [[ "$output" == *"revoke its ability to read history"* ]]
  # Where nothing keeps a copy, losing the device IS losing the key. That
  # implication belongs to this path only, so it is stated in the guidance
  # rather than left for the reader to derive.
  [[ "$output" == *"losing this device loses"* ]]
}

@test "key generate: a caller that owns the guidance gets the facts without ours" {
  skip_if_no_age
  # A larger tool runs this with stdio inherited, so whatever it prints lands
  # in front of ITS operator. Guidance written for a plain install names a
  # route that operator does not have -- and "there is no server-side
  # recovery" is simply false where the tool keeps a sealed copy on a server.
  #
  # Both directions are asserted, here and above: with only the default case,
  # a suppression that never fires would still be green, and with only this
  # one, a version that printed nothing at all would be too.
  AGMSG_OPERATOR_GUIDANCE=caller run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ]

  # Still speaks, and still says what the key IS. Silence here would be its
  # own defect: these are true however agmsg was invoked.
  [[ "$output" == *"Generated a new key for team 'testteam'"* ]]
  [[ "$output" == *"Recipient fingerprint:"* ]]
  [[ "$output" == *"no copy of it survives anywhere"* ]]
  [[ "$output" == *"becomes permanently unreadable"* ]]
  [[ "$output" == *"revoke its ability to read history"* ]]

  # And says nothing about what to do next, or where a copy is kept.
  [[ "$output" != *"Back this up now"* ]]
  [[ "$output" != *"no server-side recovery"* ]]
  [[ "$output" != *"--reveal-secret"* ]]
  [[ "$output" != *"password manager"* ]]

  # And does not assert that losing the DEVICE loses the history. That is
  # true only where nothing keeps a copy; a caller may hold a sealed copy of
  # this same key and be able to recover it. Asserting it on their behalf is
  # the same premise this change exists to stop asserting.
  [[ "$output" != *"losing this device loses"* ]]
  [[ "$output" != *"If this device is lost"* ]]
}

@test "key generate: an unrecognised guidance setting still prints the guidance" {
  skip_if_no_age
  # Fail toward speaking. A typo'd or future value must not silence a page of
  # instructions -- the quiet mode is asked for by name or not at all.
  AGMSG_OPERATOR_GUIDANCE=cloud run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ]
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
  perms=$(file_mode "$identity_file")
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
  perms=$(file_mode "$(dirname "$private_bundle")")
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
  perms=$(file_mode "$identity_file")
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

@test "key rotate: current moves only when the chain confirms the rotation" {
  skip_if_no_age
  # The other half of the staged contract. A rotation is announced locally and
  # becomes effective when the authority sequences its journal record. The
  # exported snapshot chain is the only thing that knows, so key.sh derives it
  # from there and copies it into current on its next run -- nothing writes back
  # into this ledger at confirmation time.
  bash "$SCRIPTS/key.sh" generate testteam
  local cfg_json="$SCRIPTS/../teams/testteam/config.json"
  local first; first="$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['current']['key_id'])")"

  stub_current_age_snapshot 0
  bash "$SCRIPTS/key.sh" rotate testteam >/dev/null
  local staged; staged="$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['epochs'][-1]['key_id'])")"
  [ "$staged" != "$first" ]
  # Unconfirmed: current still names the epoch actually in force.
  [ "$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['current']['key_id'])")" = "$first" ]

  # A staged rotation is visible to the reader that needs it -- rotating again
  # before the authority has spoken is refused -- without ever being treated as
  # effective.
  run bash "$SCRIPTS/key.sh" rotate testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"unacknowledged key rotation"* ]]
  [ "$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['current']['key_id'])")" = "$first" ]

  # The chain now reports the rotation as sequenced. The next key.sh run catches
  # up, and only then does current name the replacement.
  local staged_rcpt
  staged_rcpt="$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['epochs'][-1]['recipient'])")"
  stub_current_age_snapshot 1 "$staged" "$staged_rcpt"
  local identity secret
  identity="$SCRIPTS/../run/remote-credentials/testteam/keys/$staged.key"
  secret=$(grep '^AGE-SECRET-KEY-' "$identity")
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --key-id '$staged' --identity-stdin"
  [ "$status" -eq 0 ]
  [ "$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['current']['key_id'])")" = "$staged" ]
}

# Two machines can announce a rotation at the same revision. The authority
# sequences one, and the chain's tail names that one -- key and recipient
# included. Promoting on the revision alone would let a machine holding the
# other candidate install it as effective, which is the failure this whole
# change exists to prevent, in the case where it costs the most.
_add_competing_epoch() {   # $1 = config path, $2 = key_id, $3 = revision
  python3 - "$1" "$2" "$3" <<'EOS'
import json, sys
path, key_id, revision = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = json.load(open(path))
epochs = cfg["remote_key"]["epochs"]
rival = dict(epochs[-1])
rival["key_id"] = key_id
rival["epoch_revision"] = revision
rival["recipient"] = "age1" + "r" * 58
epochs.insert(len(epochs) - 1, rival)      # the rival lands FIRST
json.dump(cfg, open(path, "w"), indent=2)
EOS
}

@test "key rotate: a competing epoch at the same revision is not promoted in the winner's place" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  local cfg_json="$SCRIPTS/../teams/testteam/config.json"
  stub_current_age_snapshot 0
  bash "$SCRIPTS/key.sh" rotate testteam >/dev/null
  local winner winner_rcpt
  winner="$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['epochs'][-1]['key_id'])")"
  winner_rcpt="$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['epochs'][-1]['recipient'])")"
  _add_competing_epoch "$cfg_json" "epoch-rival-0001" 1
  # The rival is ahead of the winner in the ledger, so a revision-only match
  # would pick it.
  [ "$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['epochs'][-2]['key_id'])")" = "epoch-rival-0001" ]

  stub_current_age_snapshot 1 "$winner" "$winner_rcpt"
  bash "$SCRIPTS/key.sh" show testteam >/dev/null 2>&1 || true
  local identity secret
  identity="$SCRIPTS/../run/remote-credentials/testteam/keys/$winner.key"
  secret=$(grep '^AGE-SECRET-KEY-' "$identity")
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --key-id '$winner' --identity-stdin"
  [ "$status" -eq 0 ]
  [ "$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['current']['key_id'])")" = "$winner" ]
}

@test "key rotate: current stays put when the ledger has no entry for the confirmed winner" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  local cfg_json="$SCRIPTS/../teams/testteam/config.json"
  local first; first="$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['current']['key_id'])")"
  stub_current_age_snapshot 0
  bash "$SCRIPTS/key.sh" rotate testteam >/dev/null

  # This machine announced a rotation the authority did NOT sequence. It has no
  # copy of the winner, so there is nothing here that may become effective --
  # the winner's identity has to be imported first.
  stub_current_age_snapshot 1 "epoch-someone-elses-0001" "age1$(printf 'w%.0s' $(seq 58))"
  bash "$SCRIPTS/key.sh" show testteam >/dev/null 2>&1 || true
  local staged; staged="$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['epochs'][-1]['key_id'])")"
  local identity secret
  identity="$SCRIPTS/../run/remote-credentials/testteam/keys/$staged.key"
  secret=$(grep '^AGE-SECRET-KEY-' "$identity")
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --key-id '$staged' --identity-stdin"
  [ "$(python3 -c "import json; print(json.load(open('$cfg_json'))['remote_key']['current']['key_id'])")" = "$first" ]
}

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
  # Staged, not effective: the chain has not sequenced this rotation, so current
  # still names the epoch that is actually in force. The replacement is the
  # trailing entry in epochs.
  cfg_json="$SCRIPTS/../teams/testteam/config.json"
  [ "$(python3 -c "import json; d=json.load(open('$cfg_json')); print(d['remote_key']['current']['key_id'])")" != "$key_id" ]
  [ "$(python3 -c "import json; d=json.load(open('$cfg_json')); print(d['remote_key']['epochs'][-1]['key_id'])")" = "$key_id" ]
  [ "$(python3 -c "import json; d=json.load(open('$cfg_json')); print(len(d['remote_key']['epochs']))")" -eq 2 ]
  refute grep -q 'AGE-SECRET-KEY\\|age1' "$journal"
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

@test "key rotate: the reveal line it prints can be run as printed" {
  # The seventh printed command (#667). The other six are pinned in
  # test_printed_command_paths.bats; this one needs the rotate fixture, so it
  # lives where that fixture already is.
  #
  # argv, not a substring: the line carries a key_id as well as a team, and a
  # substring check cannot tell a correctly quoted line from one that merely
  # contains the right words. `|| return 1`, and `[ ]` rather than `[[ ]]` —
  # on bash 3.2 a bare `[[ ]]` mid-body is not enforced (#670).
  #
  # The team carries a space and a single quote, both legal (validate.sh
  # rejects empty / `.` / `..` / `/` / `\\` / a leading `-` / control
  # characters). Without them, dropping the quoting from this line still parses
  # to the same argv and the test passes — measured, not assumed.
  skip_if_no_age
  local qteam="it's a team"
  bash "$SCRIPTS/join.sh" "$qteam" alice claude-code /tmp/project-q
  bash "$SCRIPTS/key.sh" generate "$qteam"
  stub_current_age_snapshot
  config="$SCRIPTS/../teams/$qteam/config.json"
  python3 - "$config" <<'PY_BIND'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['remote_binding'] = {'server_instance_id': '018f3f7e-0000-7000-8000-000000000000',
                       'remote_team_id': '018f3f7e-0000-7000-8000-000000000001'}
open(p, 'w').write(json.dumps(d) + '\n')
PY_BIND
  run bash "$SCRIPTS/key.sh" rotate "$qteam"
  [ "$status" -eq 0 ] || return 1
  line="$(printf '%s\n' "$output" | grep -F -- "key.sh' show " | head -1)"
  [ -n "$line" ] || return 1
  eval "set -- $line"
  [ "$1" = bash ] || return 1
  [ -f "$2" ] || return 1
  [ "$3" = show ] || return 1
  [ "$4" = "$qteam" ] || return 1
  [ "$5" = --key-id ] || return 1
  # The key_id it names is the replacement this run just generated, not the
  # retired one: the same command pointing at the wrong secret would still
  # parse. Taken from the run's own "Generated replacement key" line rather
  # than from the config, because a rotation that is not yet confirmed leaves
  # `remote_key.current` on the previous key.
  [ -n "$6" ] || return 1
  generated="$(printf '%s\n' "$output" | sed -n 's/.*Generated replacement key .*key_id=\([^)]*\)).*/\1/p' | head -1)"
  [ -n "$generated" ] || return 1
  [ "$6" = "$generated" ] || return 1
  [ "$7" = --reveal-secret ] || return 1
}

@test "key rotate: refuses a team with no current key" {
  run bash "$SCRIPTS/key.sh" rotate testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"no current key"* ]]
}

# --- fingerprint: never print one that was not computed (#861) -------------

# A recipient fingerprint exists so two people can read the same short string
# to each other over a separate channel and agree they hold the same key. If
# the digest cannot be computed, BOTH of them see an empty string and both say
# it matches. That is worse than no fingerprint at all, so a digest that fails
# has to stop the command rather than print a label with nothing after it.
#
# Driven by making the first digest arm fail rather than by emptying PATH:
# key.sh needs a dozen other tools to reach this line, and a PATH restricted
# far enough to hide `shasum` would stop it long before the fingerprint for
# reasons that have nothing to do with #861.
break_the_digest() {
  local shim="$TEST_SKILL_DIR/broken-digest"
  mkdir -p "$shim"
  # All three arms, so this does not quietly become "the second arm answered".
  local tool
  for tool in shasum sha256sum openssl; do
    printf '#!/bin/sh\nexit 1\n' > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  printf '%s' "$shim"
}

@test "key generate: a digest that fails stops the command, no blank fingerprint" {
  skip_if_no_age
  local shim; shim="$(break_the_digest)"
  run env PATH="$shim:$PATH" bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -ne 0 ]
  # The label must not appear with an empty value after it. Matching the label
  # plus end-of-line is the whole point: `*"Recipient fingerprint:"*` would be
  # satisfied by exactly the broken output this test exists to reject.
  refute grep -qE 'Recipient fingerprint: *$' <<<"$output"
}

@test "key show: a digest that fails stops the command, no blank fingerprint" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  local shim; shim="$(break_the_digest)"
  run env PATH="$shim:$PATH" bash "$SCRIPTS/key.sh" show testteam
  [ "$status" -ne 0 ]
  refute grep -qE 'Recipient fingerprint: *$' <<<"$output"
}

# A TOOL THAT SUCCEEDS AND LIES. The shim above exits 1, which any status check
# catches. This one exits 0 and prints a well-formed digest that is not the
# digest of the input — and `key.sh` is its own CLI: `generate`, `show`,
# `import` and `rotate` all reach a digest without passing `connect`'s
# preflight, so for one head the preflight was the only thing asking whether the
# answer was right and none of these four asked it. Raised in review.
#
# Driven from `key.sh` deliberately, not from the helper: the claim is about
# what this command does, and a helper-level case cannot fail if a caller stops
# using the helper.
@test "key generate: a tool that returns the wrong digest stops the command" {
  skip_if_no_age
  local shim="$TEST_SKILL_DIR/lying-digest"
  mkdir -p "$shim"
  local tool
  for tool in shasum sha256sum openssl; do
    printf '#!/bin/sh\ncat >/dev/null\necho "%s  -"\n' \
      1111111111111111111111111111111111111111111111111111111111111111 > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  # Control: it exits 0 and its answer has the shape of a digest, so nothing
  # short of asking a question with a known answer distinguishes it.
  run env PATH="$shim:$PATH" bash -c 'printf x | shasum -a 256'
  [ "$status" -eq 0 ]

  run env PATH="$shim:$PATH" bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -ne 0 ]
  refute grep -qE '1111111111111111' <<<"$output"
}

# The control for the three above: with the digest working, the same commands
# print a fingerprint that is actually there. Without this, they would all
# still pass if key.sh had simply stopped working entirely.
@test "key generate: the working case still prints a non-empty fingerprint" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE 'Recipient fingerprint: [0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}$'
}

# --- dispatch --------------------------------------------------------------

@test "key.sh: unknown subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/key.sh" bogus testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
