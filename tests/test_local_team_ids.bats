#!/usr/bin/env bats

load test_helper

UUID7_RE='^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

config_field() {
  local cfg="$1" path="$2" escaped
  escaped="$(sed "s/'/''/g" "$cfg")"
  sqlite_mem "SELECT json_extract('$escaped', '$path');"
}

write_legacy_team() {
  local team="$1" agents="$2"
  mkdir -p "$TEST_SKILL_DIR/teams/$team"
  printf '{"name":"%s","agents":%s,"created_at":"2026-01-01T00:00:00Z"}\n' \
    "$team" "$agents" > "$TEST_SKILL_DIR/teams/$team/config.json"
}

@test "new joins mint stable UUIDv7 team and member identities" {
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/project-a
  local cfg="$TEST_SKILL_DIR/teams/demo/config.json"
  local team_id alice_id first
  team_id="$(config_field "$cfg" '$.team_id')"
  alice_id="$(config_field "$cfg" '$.agents.alice.member_id')"
  [[ "$team_id" =~ $UUID7_RE ]]
  [[ "$alice_id" =~ $UUID7_RE ]]
  [ "$team_id" != "$alice_id" ]

  first="$(cat "$cfg")"
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/project-a
  [ "$(cat "$cfg")" = "$first" ]

  bash "$SCRIPTS/join.sh" demo bob codex /tmp/project-b
  local bob_id
  bob_id="$(config_field "$cfg" '$.agents.bob.member_id')"
  [[ "$bob_id" =~ $UUID7_RE ]]
  [ "$bob_id" != "$alice_id" ]
  [ "$(config_field "$cfg" '$.team_id')" = "$team_id" ]
  [ "$(config_field "$cfg" '$.agents.alice.member_id')" = "$alice_id" ]
}

@test "a team never mixes members with and without identities" {
  write_legacy_team legacy \
    '{"alice":{"type":"claude-code","project":"/tmp/project-a"}}'
  bash "$SCRIPTS/join.sh" legacy bob codex /tmp/project-b
  local legacy_cfg="$TEST_SKILL_DIR/teams/legacy/config.json"
  [ -z "$(config_field "$legacy_cfg" '$.team_id')" ]
  [ "$(sqlite_mem "SELECT COUNT(*) FROM json_each(
    json_extract(CAST(readfile('$(rf "$legacy_cfg")') AS TEXT), '\$.agents')
  ) WHERE json_type(value, '\$.member_id') IS NOT NULL;")" -eq 0 ]

  bash "$SCRIPTS/join.sh" current alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" current bob codex /tmp/project-b
  local current_cfg="$TEST_SKILL_DIR/teams/current/config.json"
  [[ "$(config_field "$current_cfg" '$.team_id')" =~ $UUID7_RE ]]
  [ "$(sqlite_mem "SELECT COUNT(*) FROM json_each(
    json_extract(CAST(readfile('$(rf "$current_cfg")') AS TEXT), '\$.agents')
  ) WHERE json_type(value, '\$.member_id') = 'text';")" -eq 2 ]
}

@test "agent and team renames preserve identities on a current team" {
  bash "$SCRIPTS/join.sh" old-team alice claude-code /tmp/a
  bash "$SCRIPTS/rename.sh" old-team alice renamed
  local old_cfg="$TEST_SKILL_DIR/teams/old-team/config.json"
  local team_id member_id
  team_id="$(config_field "$old_cfg" '$.team_id')"
  member_id="$(config_field "$old_cfg" '$.agents.renamed.member_id')"
  [[ "$team_id" =~ $UUID7_RE ]]
  [[ "$member_id" =~ $UUID7_RE ]]

  bash "$SCRIPTS/rename-team.sh" old-team new-team
  local new_cfg="$TEST_SKILL_DIR/teams/new-team/config.json"
  [ "$(config_field "$new_cfg" '$.team_id')" = "$team_id" ]
  [ "$(config_field "$new_cfg" '$.agents.renamed.member_id')" = "$member_id" ]
  [ "$(config_field "$new_cfg" '$.name')" = "new-team" ]
}

@test "core join does not require python3" {
  local no_python cmd
  no_python="$(mktemp -d)"
  for cmd in bash dirname sqlite3 sed date mkdir rmdir cat mv head od tr sort basename paste; do
    ln -s "$(command -v "$cmd")" "$no_python/$cmd"
  done

  env PATH="$no_python" bash "$SCRIPTS/join.sh" demo alice codex /tmp/project
  local cfg="$TEST_SKILL_DIR/teams/demo/config.json"
  [[ "$(config_field "$cfg" '$.team_id')" =~ $UUID7_RE ]]
  [[ "$(config_field "$cfg" '$.agents.alice.member_id')" =~ $UUID7_RE ]]
  [ ! -d "$TEST_SKILL_DIR/teams/demo/.config.lock" ]
}

@test "core UUID generation never executes an unusable python3" {
  local fake_bin marker
  fake_bin="$(mktemp -d)"
  marker="$TEST_SKILL_DIR/python-executed"
  printf '#!/usr/bin/env bash\n: > "$PYTHON_MARKER"\nexit 99\n' > "$fake_bin/python3"
  chmod +x "$fake_bin/python3"

  PYTHON_MARKER="$marker" PATH="$fake_bin:$PATH" \
    bash "$SCRIPTS/join.sh" demo alice codex /tmp/project
  local cfg="$TEST_SKILL_DIR/teams/demo/config.json"
  [ ! -e "$marker" ]
  [[ "$(config_field "$cfg" '$.team_id')" =~ $UUID7_RE ]]
  [[ "$(config_field "$cfg" '$.agents.alice.member_id')" =~ $UUID7_RE ]]
}
