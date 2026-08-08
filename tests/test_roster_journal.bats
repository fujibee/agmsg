#!/usr/bin/env bats

load test_helper

UUID7_RE='^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

journal_query() {
  local journal="$1" query="$2"
  sqlite_mem "
    WITH source(doc) AS (
      SELECT '[' || replace(
        rtrim(CAST(readfile('$(rf "$journal")') AS TEXT), char(10)),
        char(10), ',') || ']'
    ),
    records AS (SELECT CAST(key AS INTEGER) AS ord,value AS event
                  FROM source,json_each(source.doc))
    $query"
}

config_field() {
  local config="$1" path="$2"
  sqlite_mem "SELECT json_extract(
    CAST(readfile('$(rf "$config")') AS TEXT), '$path');"
}

@test "join records one stable identity event per new member" {
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local config="$TEST_SKILL_DIR/teams/demo/config.json"
  local journal="$TEST_SKILL_DIR/teams/demo/roster.jsonl"
  [ -f "$journal" ]

  local member_id
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  [[ "$member_id" =~ $UUID7_RE ]]
  [ "$(journal_query "$journal" \
    "SELECT count(*) FROM records
      WHERE json_extract(event,'\$.type')='member_joined'
        AND json_extract(event,'\$.member_id')='$member_id'
        AND json_extract(event,'\$.name')='alice';")" -eq 1 ]

  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/b
  [ "$(journal_query "$journal" \
    "SELECT count(*) FROM records
      WHERE json_extract(event,'\$.type')='member_joined';")" -eq 1 ]

  bash "$SCRIPTS/join.sh" demo bob codex /tmp/c
  [ "$(journal_query "$journal" \
    "SELECT count(*) FROM records
      WHERE json_extract(event,'\$.type')='member_joined';")" -eq 2 ]
}

@test "leave appends identity history and retains an empty current team" {
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local journal="$team_dir/roster.jsonl"
  local member_id
  member_id="$(config_field "$config" '$.agents.alice.member_id')"

  run bash "$SCRIPTS/leave.sh" demo alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"team retained"* ]]
  [ -d "$team_dir" ]
  [ -f "$config" ]
  [ -f "$journal" ]
  [ "$(config_field "$config" '$.agents')" = "{}" ]
  [ "$(journal_query "$journal" \
    "SELECT count(*) FROM records
      WHERE json_extract(event,'\$.type')='member_left'
        AND json_extract(event,'\$.member_id')='$member_id'
        AND json_extract(event,'\$.name')='alice';")" -eq 1 ]
}

@test "a retired member rejoins with the same identity" {
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local config="$TEST_SKILL_DIR/teams/demo/config.json"
  local member_id
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  bash "$SCRIPTS/leave.sh" demo alice

  [ "$(config_field "$config" '$.retired_members.alice.member_id')" = "$member_id" ]
  bash "$SCRIPTS/join.sh" demo alice codex /tmp/b
  [ "$(config_field "$config" '$.agents.alice.member_id')" = "$member_id" ]
  [ "$(config_field "$config" '$.retired_members.alice')" = "" ]
}

@test "journal projection keeps the first identity bound to a name" {
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local first second
  first="$(config_field "$config" '$.agents.alice.member_id')"

  # Simulate a concurrent machine proposing the same name before synchronization.
  source "$SCRIPTS/lib/roster-journal.sh"
  second="$(compat_uuid7)"
  agmsg_roster_append_joined "$team_dir" "$second" alice "2026-01-01T00:00:00Z"
  agmsg_roster_project_config "$team_dir" "$config"

  [ "$(config_field "$config" '$.agents.alice.member_id')" = "$first" ]
  [ "$(journal_query "$team_dir/roster.jsonl" \
    "SELECT count(*) FROM records
      WHERE json_extract(event,'\$.type')='member_joined'
        AND json_extract(event,'\$.name')='alice';")" -eq 2 ]
}

@test "rename preserves member identity and records a compare-and-swap event" {
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id
  member_id="$(config_field "$config" '$.agents.alice.member_id')"

  bash "$SCRIPTS/rename.sh" demo alice carol

  [ "$(config_field "$config" '$.agents.carol.member_id')" = "$member_id" ]
  [ "$(config_field "$config" '$.agents.alice')" = "" ]
  [ "$(journal_query "$team_dir/roster.jsonl" \
    "SELECT count(*) FROM records
      WHERE json_extract(event,'\$.type')='member_renamed'
        AND json_extract(event,'\$.member_id')='$member_id'
        AND json_extract(event,'\$.from')='alice'
        AND json_extract(event,'\$.to')='carol';")" -eq 1 ]
}

@test "concurrent renames accept only the first event whose from name is current" {
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id
  member_id="$(config_field "$config" '$.agents.alice.member_id')"

  source "$SCRIPTS/lib/roster-journal.sh"
  agmsg_roster_append_renamed "$team_dir" "$member_id" alice carol \
    "2026-01-01T00:00:00Z"
  agmsg_roster_append_renamed "$team_dir" "$member_id" alice dave \
    "2026-01-01T00:00:01Z"
  agmsg_roster_project_config "$team_dir" "$config"

  [ "$(config_field "$config" '$.agents.carol.member_id')" = "$member_id" ]
  [ "$(config_field "$config" '$.agents.dave')" = "" ]
}

@test "name-only legacy teams keep their existing deletion behavior" {
  mkdir -p "$TEST_SKILL_DIR/teams/legacy"
  printf '%s\n' \
    '{"name":"legacy","agents":{"alice":{"type":"claude-code","project":"/tmp/a"}}}' \
    > "$TEST_SKILL_DIR/teams/legacy/config.json"

  bash "$SCRIPTS/leave.sh" legacy alice
  [ ! -e "$TEST_SKILL_DIR/teams/legacy" ]
}

@test "roster sync exits on TERM without projecting after releasing the lock" {
  skip_on_windows "POSIX signal delivery is not supported by this test"
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id marker child_pid_file fake wrapper_pid child_pid wrapper_status=0
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  source "$SCRIPTS/lib/roster-journal.sh"
  agmsg_roster_append_left "$team_dir" "$member_id" alice \
    "2026-01-01T00:00:00Z"

  marker="$TEST_SKILL_DIR/fake-node-started"
  child_pid_file="$TEST_SKILL_DIR/fake-node.pid"
  fake="$TEST_SKILL_DIR/fake-node"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$AGMSG_TEST_CHILD_PID"
: > "$AGMSG_TEST_MARKER"
trap 'exit 0' TERM INT HUP
while :; do sleep 1; done
EOF
  chmod +x "$fake"

  AGMSG_TEST_MARKER="$marker" AGMSG_TEST_CHILD_PID="$child_pid_file" \
    AGMSG_SYNC_NODE_BIN="$fake" \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 \
      </dev/null >/dev/null 2>&1 &
  wrapper_pid=$!
  wait_for_file "$marker"
  kill -TERM "$wrapper_pid"
  child_pid="$(cat "$child_pid_file")"
  kill -TERM "$child_pid" 2>/dev/null || true
  wait "$wrapper_pid" || wrapper_status=$?
  [ "$wrapper_status" -ne 0 ]

  [ ! -d "$team_dir/.config.lock" ]
  [ "$(config_field "$config" '$.agents.alice.member_id')" = "$member_id" ]
}

# The failure this covers is not "the projection was empty" -- it is that an
# empty projection had two causes and reported neither. readfile() returns NULL
# for a path it cannot open, that NULL collapses the whole expression, and the
# caller saw the same "" a genuinely empty roster produces. join.sh printed
# "Created team:" and exited 1 with nothing on stderr (#669).
#
# An unreadable file is the portable way to make readfile() return NULL. On
# Windows the same NULL arrived from a path sqlite3.exe could not open, which is
# what the conversion in _agmsg_roster_readfile_path fixes; this pins the half
# that can be observed anywhere.
@test "roster projection names the file it could not read instead of failing silently" {
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local config="$TEST_SKILL_DIR/teams/demo/config.json"
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  [ -f "$config" ]

  chmod 000 "$config"
  run bash -c '. "$1/lib/roster-journal.sh"; agmsg_roster_project_config "$2" "$3"' _ \
    "$SCRIPTS" "$team_dir" "$config"
  chmod 644 "$config"

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read"* ]]
  [[ "$output" == *"config.json"* ]]
}
