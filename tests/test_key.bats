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

# key.sh needs the real `age`/`age-keygen` binaries (ADR 0007 §8) — skip
# gracefully rather than failing when they're not installed on the runner.
skip_if_no_age() {
  command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 || skip "age/age-keygen not installed"
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
  [[ "$output" == *"rotate"* ]]
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

# --- import --------------------------------------------------------------

@test "key import: establishes the first epoch for a team with no key yet" {
  skip_if_no_age
  secret=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')
  run bash "$SCRIPTS/key.sh" import testteam "$secret"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Imported key for team 'testteam'"* ]]
}

@test "key import: matching identity for an already-keyed team succeeds without a new epoch" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  key_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['current']['key_id'])")
  secret=$(grep '^AGE-SECRET-KEY-' "$SCRIPTS/../run/remote-credentials/testteam/keys/$key_id.key")
  before=$(python3 -c "import json; print(len(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['epochs']))")
  run bash "$SCRIPTS/key.sh" import testteam "$secret"
  [ "$status" -eq 0 ]
  after=$(python3 -c "import json; print(len(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['epochs']))")
  [ "$before" = "$after" ]
}

@test "key import: mismatched identity for an already-keyed team is rejected (fail closed)" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  other_secret=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')
  run bash "$SCRIPTS/key.sh" import testteam "$other_secret"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
}

@test "key import: rejects a malformed identity string" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" import testteam "not-a-real-identity"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a well-formed age identity"* ]]
}

# --- rotate --------------------------------------------------------------

@test "key rotate: starts a new epoch and increments epoch_revision" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  run bash "$SCRIPTS/key.sh" rotate testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"epoch_revision 0 -> 1"* ]]
  epoch=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['current']['epoch_revision'])")
  [ "$epoch" = "1" ]
}

@test "key rotate: never re-encrypts, retains all prior epochs and their identity files" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  first_key_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['current']['key_id'])")
  bash "$SCRIPTS/key.sh" rotate testteam
  bash "$SCRIPTS/key.sh" rotate testteam
  epochs=$(python3 -c "import json; print(len(json.load(open('$SCRIPTS/../teams/testteam/config.json'))['remote_key']['epochs']))")
  [ "$epochs" -eq 3 ]
  [ -f "$SCRIPTS/../run/remote-credentials/testteam/keys/$first_key_id.key" ]
}

@test "key rotate: repeated rotations within the same second each get a distinct key_id" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  bash "$SCRIPTS/key.sh" rotate testteam
  bash "$SCRIPTS/key.sh" rotate testteam
  ids=$(python3 -c "import json; d=json.load(open('$SCRIPTS/../teams/testteam/config.json')); print(len(set(e['key_id'] for e in d['remote_key']['epochs'])))")
  [ "$ids" = "3" ]
}

@test "key rotate: fails when the team has no existing key" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" rotate testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"no existing key to rotate"* ]]
}

@test "key rotate: fails for an unknown team" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" rotate notateam
  [ "$status" -ne 0 ]
  [[ "$output" == *"team not found"* ]]
}

# --- dispatch --------------------------------------------------------------

@test "key.sh: unknown subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/key.sh" bogus testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
