#!/usr/bin/env bats

load test_helper

# Rows the sync engine found it cannot send and left out of the push so the rest
# went through. What is tested here is the reading: `status` names the message
# and the reason in one line, `status --json` carries the rows, and a record
# that is absent or unreadable reads as "nothing skipped".

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem "
    SELECT json_set('$escaped', '\$.remote_binding', json_object(
      'endpoint', 'https://sync.example.test',
      'server_instance_id', '018f0000-0000-7000-8000-000000000001',
      'remote_team_id', '018f0000-0000-7000-8000-000000000002',
      'protocol_version', 1,
      'capabilities', json_object('write_allowed_ciphers', json_array('none')),
      'connected_at', '2026-07-30T00:00:00Z',
      'disconnected_at', null
    ));")"
  printf '%s\n' "$updated" > "$cfg"
  mkdir -p "$TEST_SKILL_DIR/run"
}

teardown() { teardown_test_env; }

# What the engine writes; written here because this file is about what READS it.
write_skipped() {
  printf '%s\n' '{"type":"sync_skipped_rows","updated_at":"2026-11-08T00:00:00Z","rows":[{"direction":"push","local_position":"2","id":"01a1bd0d-ab00-7b4c-8a5a-d62d6be756dc","reason":"malformed: from_agent is invalid","first_seen":"2026-11-08T00:00:00Z","count":1}]}' \
    > "$TEST_SKILL_DIR/run/remote-sync.testteam.skipped.json"
}

@test "status names a skipped message and why, and says the rest went through" {
  write_skipped
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  grep -qF 'skipped: message 01a1bd0d-ab00-7b4c-8a5a-d62d6be756dc could not be sent (push: malformed: from_agent is invalid); the rest went through' <<<"$output"
}

@test "status --json carries the skipped rows, and null when there are none" {
  run bash "$SCRIPTS/remote.sh" status --json testteam
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.skipped')" = null ]
  write_skipped
  run bash "$SCRIPTS/remote.sh" status --json testteam
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.skipped[0].id')" = 01a1bd0d-ab00-7b4c-8a5a-d62d6be756dc ]
  [ "$(printf '%s' "$output" | jq -r '.skipped[0].local_position')" = 2 ]
}

@test "an unreadable skipped record reads as nothing skipped" {
  printf '%s\n' 'not json {' > "$TEST_SKILL_DIR/run/remote-sync.testteam.skipped.json"
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  refute grep -q 'skipped:' <<<"$output"
  run bash "$SCRIPTS/remote.sh" status --json testteam
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.skipped')" = null ]
}
