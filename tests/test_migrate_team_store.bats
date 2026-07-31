#!/usr/bin/env bats

load test_helper

# migrate-team-store.sh moves ONE team out of the shared store. Connecting is
# what calls it; nothing else does, and installing must never call it — programs
# outside agmsg read the shared store directly, and an install that relocated
# their data would break them with no error anywhere.

setup() {
  setup_test_env
  SHARED="$TEST_SKILL_DIR/db/messages.db"
  export SKILL_DIR="$TEST_SKILL_DIR"
  bash "$SCRIPTS/join.sh" alpha ann claude-code /tmp/alpha-ann >/dev/null
  bash "$SCRIPTS/join.sh" alpha bob claude-code /tmp/alpha-bob >/dev/null
  bash "$SCRIPTS/join.sh" beta  ann claude-code /tmp/beta-ann  >/dev/null
  bash "$SCRIPTS/join.sh" beta  bob claude-code /tmp/beta-bob  >/dev/null
}

teardown() { teardown_test_env; }

migrate() { bash "$SCRIPTS/internal/migrate-team-store.sh" "$@"; }

store_of() {
  ( # shellcheck disable=SC1091
    source "$SCRIPTS/lib/storage.sh"; agmsg_db_path "$1" )
}

shared_rows() {
  sqlite3 "$SHARED" \
    "SELECT COUNT(*) FROM events WHERE type='message_sent' AND team='$1';" | tr -d '\r'
}

@test "migrate: only the named team moves" {
  bash "$SCRIPTS/send.sh" alpha ann bob "alpha-one" >/dev/null
  bash "$SCRIPTS/send.sh" beta  ann bob "beta-one"  >/dev/null

  run migrate alpha
  [ "$status" -eq 0 ]

  [ "$(store_of alpha)" = "$TEST_SKILL_DIR/db/teams/alpha/messages.db" ]
  # The neighbour is exactly where it was. This is the property the axis exists
  # for: connecting one team must not relocate anyone else's data.
  [ "$(store_of beta)" = "$SHARED" ]
  [ "$(shared_rows beta)" -eq 1 ]
}

@test "migrate: the moved team is removed from the shared store" {
  bash "$SCRIPTS/send.sh" alpha ann bob "alpha-one" >/dev/null
  migrate alpha
  # Left behind, those rows would freeze at today's date for every program that
  # reads the shared store — present, plausible, never updated again. Zero rows
  # is something a reader can notice.
  [ "$(shared_rows alpha)" -eq 0 ]
}

@test "migrate: the history is still readable afterwards" {
  bash "$SCRIPTS/send.sh" alpha ann bob "from before the move" >/dev/null
  migrate alpha
  run bash "$SCRIPTS/history.sh" alpha bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "from before the move" ]]
}

@test "migrate: new messages keep arriving after the move" {
  bash "$SCRIPTS/send.sh" alpha ann bob "before" >/dev/null
  migrate alpha
  bash "$SCRIPTS/send.sh" alpha ann bob "after" >/dev/null
  run bash "$SCRIPTS/inbox.sh" alpha bob
  [[ "$output" =~ "before" ]]
  [[ "$output" =~ "after" ]]
  # ...and they land in the team's own store, not back in the shared one.
  [ "$(shared_rows alpha)" -eq 0 ]
}

@test "migrate: running it again is a no-op" {
  bash "$SCRIPTS/send.sh" alpha ann bob "alpha-one" >/dev/null
  migrate alpha
  local before; before=$(cksum "$(store_of alpha)")
  run migrate alpha
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already has its own store" ]]
  [ "$(cksum "$(store_of alpha)")" = "$before" ]
}

@test "migrate: refuses to merge into a store that already exists" {
  # Colliding seq values would be dropped by INSERT OR IGNORE, losing history in
  # the case that looks like success.
  bash "$SCRIPTS/send.sh" alpha ann bob "shared-side" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/db/teams/alpha"
  sqlite3 "$TEST_SKILL_DIR/db/teams/alpha/messages.db" "CREATE TABLE messages(id INTEGER);"
  run migrate alpha
  [ "$status" -ne 0 ]
  [[ "$output" =~ "refusing to merge" ]]
  # The team did not move, so its rows are still where readers expect them.
  [ "$(shared_rows alpha)" -eq 1 ]
}

@test "migrate: a moved team can still be renamed, and its store follows" {
  # Renaming a shared-partition team rewrites a column; renaming a moved one has to
  # move a directory as well. Only the second path exists after a migration, so
  # it is covered here rather than beside the shared-partition rename tests.
  bash "$SCRIPTS/send.sh" alpha ann bob "carried across" >/dev/null
  migrate alpha
  [ -e "$TEST_SKILL_DIR/db/teams/alpha/messages.db" ]

  run bash "$SCRIPTS/rename-team.sh" alpha gamma
  [ "$status" -eq 0 ]

  [ ! -e "$TEST_SKILL_DIR/db/teams/alpha/messages.db" ]
  [ -e "$TEST_SKILL_DIR/db/teams/gamma/messages.db" ]
  run bash "$SCRIPTS/history.sh" gamma bob
  [[ "$output" =~ "carried across" ]]
}

@test "migrate: a team that does not exist is refused" {
  run migrate nosuchteam
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Team not found" ]]
}

@test "migrate: a team name that cannot be a directory is refused" {
  # Stores from before team-name validation (#140) hold names like this; a real
  # one held an absolute project path.
  run migrate "/Users/someone/project"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_SKILL_DIR/db/teams/Users" ]
}

@test "migrate: installing moves nothing" {
  # The regression that matters most: an install that relocated stores would
  # break every external reader at once, silently. install.sh must not CALL it —
  # the comment there that points at this script is the documentation, so the
  # check skips comment lines rather than matching the name anywhere.
  local called
  # grep -n on ONE file prints "NNN:text" with no leading filename, so the
  # comment filter anchors at the start rather than after a colon.
  called="$(grep -n 'migrate-team-store' "$BATS_TEST_DIRNAME/../install.sh" \
    | grep -v '^[0-9]*: *#' || true)"
  [ -z "$called" ] || { echo "$called"; false; }
}
