#!/usr/bin/env bats

# Windows path-form compatibility for project identity resolution (#268).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"

  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/resolve-project.sh"
}

teardown() {
  teardown_test_env
}

write_team_config() {
  local project="$1" type="${2:-codex}" agent="${3:-alice}"
  local project_sql type_sql agent_sql
  project_sql=$(printf '%s' "$project" | sed "s/'/''/g")
  type_sql=$(printf '%s' "$type" | sed "s/'/''/g")
  agent_sql=$(printf '%s' "$agent" | sed "s/'/''/g")
  mkdir -p "$TEST_SKILL_DIR/teams/team"
  sqlite3 :memory: "
    SELECT json_object(
      'name', 'team',
      'agents', json_object(
        '$agent_sql',
        json_object(
          'registrations',
          json_array(json_object('type', '$type_sql', 'project', '$project_sql'))
        )
      )
    );
  " > "$TEST_SKILL_DIR/teams/team/config.json"
}

assert_identity_for() {
  local input="$1"
  run bash "$SCRIPTS/identities.sh" "$input" codex
  [ "$status" -eq 0 ]
  [[ "$output" =~ $'team\talice' ]]
}

@test "normalize: Windows path forms become uppercase-drive mixed form" {
  [ "$(agmsg_normalize_project_path '/c/Users/regis/Proj/')" = "C:/Users/regis/Proj" ]
  [ "$(agmsg_normalize_project_path 'c:/Users/regis/Proj/')" = "C:/Users/regis/Proj" ]
  [ "$(agmsg_normalize_project_path 'C:\Users\regis\Proj\')" = "C:/Users/regis/Proj" ]
}

@test "normalize: root paths are preserved" {
  [ "$(agmsg_normalize_project_path 'C:/')" = "C:/" ]
  [ "$(agmsg_normalize_project_path 'C:////')" = "C:/" ]
  [ "$(agmsg_normalize_project_path '/c/')" = "C:/" ]
  [ "$(agmsg_normalize_project_path '/')" = "/" ]
}

@test "identities: stored mixed path matches common Windows input forms" {
  write_team_config 'C:/x'

  assert_identity_for '/c/x'
  assert_identity_for 'C:\x'
  assert_identity_for 'C:/x/'
  assert_identity_for 'c:/x'
}

@test "identities: legacy stored MSYS path matches mixed input form" {
  write_team_config '/c/x'

  assert_identity_for 'C:/x'
}

@test "identities: Windows variant SQL remains safe for single quotes" {
  write_team_config "C:/x's"

  assert_identity_for "/c/x's"
}

@test "identities: non-Windows path strips trailing slash and still matches" {
  write_team_config '/tmp/agmsg-proj'

  assert_identity_for '/tmp/agmsg-proj/'
}

@test "normalize: repeated slashes collapse, UNC leading slashes survive" {
  [ "$(agmsg_normalize_project_path 'C://x//y')" = "C:/x/y" ]
  [ "$(agmsg_normalize_project_path '/c//x')" = "C:/x" ]
  [ "$(agmsg_normalize_project_path '//server/share/repo')" = "//server/share/repo" ]
}

@test "identities: UNC registration matches across slash and backslash forms" {
  write_team_config '\\server\share\repo'

  assert_identity_for '//server/share/repo'
  assert_identity_for '\\server\share\repo'
}

@test "identities: legacy POSIX registration with trailing slash still matches" {
  write_team_config '/tmp/agmsg-proj/'

  assert_identity_for '/tmp/agmsg-proj'
}

@test "join: stores canonical mixed Windows path going forward" {
  AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice codex '/c/x/' >/dev/null

  cfg="$TEST_SKILL_DIR/teams/team/config.json"
  project="$(sqlite_mem "SELECT json_extract(readfile('$(rf "$cfg")'), '\$.agents.alice.registrations[0].project');")"
  [ "$project" = "C:/x" ]
}
