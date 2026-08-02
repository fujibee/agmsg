#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-b
}

teardown() {
  teardown_test_env
}

# --- export.sh (plaintext JSONL over the storage contract) ---

@test "export: emits message_sent JSONL to stdout" {
  bash "$SCRIPTS/send.sh" testteam alice bob "msg1"
  bash "$SCRIPTS/send.sh" testteam bob alice "msg2"
  run bash "$SCRIPTS/export.sh" --team testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ \"type\":\"message_sent\" ]]
  [[ "$output" =~ "msg1" ]]
  [[ "$output" =~ "msg2" ]]
}

@test "export: every line is a JSON object with the message_sent fields" {
  bash "$SCRIPTS/send.sh" testteam alice bob "hello"
  run bash "$SCRIPTS/export.sh" --team testteam
  [ "$status" -eq 0 ]
  # Each line parses as JSON and carries the contract fields (id/team/from/to/body/at).
  # Count validated lines so an empty output cannot pass this vacuously.
  local n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "$line" | jq -e '.type=="message_sent" and .id and .team and .from and .to and (.body!=null) and .at' >/dev/null
    n=$((n + 1))
  done <<< "$output"
  [ "$n" -ge 1 ]
}

@test "export: chronological order — oldest line first" {
  bash "$SCRIPTS/send.sh" testteam alice bob "first"
  bash "$SCRIPTS/send.sh" testteam alice bob "second"
  run bash "$SCRIPTS/export.sh" --team testteam
  [ "$status" -eq 0 ]
  local first_line second_line
  first_line="$(printf '%s\n' "$output" | sed -n '1p')"
  second_line="$(printf '%s\n' "$output" | sed -n '2p')"
  [[ "$first_line" =~ "first" ]]
  [[ "$second_line" =~ "second" ]]
}

@test "export: --agent limits to that agent" {
  bash "$SCRIPTS/send.sh" testteam alice bob "to-bob"
  bash "$SCRIPTS/send.sh" testteam bob alice "to-alice"
  # carol never joined; filtering to her yields no records
  run bash "$SCRIPTS/export.sh" --team testteam --agent carol
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "export: --limit keeps the most recent N" {
  bash "$SCRIPTS/send.sh" testteam alice bob "m1"
  bash "$SCRIPTS/send.sh" testteam alice bob "m2"
  bash "$SCRIPTS/send.sh" testteam alice bob "m3"
  run bash "$SCRIPTS/export.sh" --team testteam --limit 1
  [ "$status" -eq 0 ]
  local count
  count="$(printf '%s\n' "$output" | grep -c '"type":"message_sent"')"
  [ "$count" -eq 1 ]
  [[ "$output" =~ "m3" ]]
}

@test "export: --out writes the JSONL to a file, stdout stays empty" {
  bash "$SCRIPTS/send.sh" testteam alice bob "saved"
  local out="$TEST_SKILL_DIR/export.jsonl"
  run bash "$SCRIPTS/export.sh" --team testteam --out "$out"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$out" ]
  grep -q '"type":"message_sent"' "$out"
  grep -q "saved" "$out"
}

@test "export: an empty team exports nothing, exit 0" {
  run bash "$SCRIPTS/export.sh" --team testteam
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "export: --team is required" {
  run bash "$SCRIPTS/export.sh"
  [ "$status" -eq 2 ]
}

@test "export: an unknown flag is rejected" {
  run bash "$SCRIPTS/export.sh" --team testteam --bogus
  [ "$status" -eq 2 ]
}
