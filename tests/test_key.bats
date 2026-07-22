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

@test "key import --identity-stdin: establishes the first epoch for a team with no key yet" {
  skip_if_no_age
  secret=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-')
  run bash -c "printf '%s' '$secret' | bash '$SCRIPTS/key.sh' import testteam --identity-stdin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Imported key for team 'testteam'"* ]]
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

# --- rotate (NOT READY) --------------------------------------------------

@test "key rotate: refuses unconditionally and changes no state (NOT READY)" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam
  before=$(cat "$SCRIPTS/../teams/testteam/config.json")
  run bash "$SCRIPTS/key.sh" rotate testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"not available in this release"* ]]
  after=$(cat "$SCRIPTS/../teams/testteam/config.json")
  [ "$before" = "$after" ]
}

@test "key rotate: refuses even for a team with no key at all" {
  run bash "$SCRIPTS/key.sh" rotate testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"not available in this release"* ]]
}

# --- dispatch --------------------------------------------------------------

@test "key.sh: unknown subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/key.sh" bogus testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
