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
  # And it says what to do — the verification failure below already did, and a
  # reader who hits this one first should not have to guess.
  [[ "$output" =~ "remove" ]]
  # With the caveat that makes the advice safe. Following it after a team is
  # recorded as moved would destroy the live store, which is the loss this
  # change exists to prevent.
  [[ "$output" =~ "NOT yet" ]]
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

# The loss pm's advisory describes: a run interrupted after the config flipped
# leaves rows in BOTH stores, and re-running with the destination gone deletes
# the shared copy on the strength of the flag alone.
#
# Written as "the rows survive". Remove the guard and the shared store is
# emptied, so this fails by losing data rather than by a changed message.
@test "migrate: a destination that vanished does not take the shared rows with it" {
  bash "$SCRIPTS/send.sh" alpha ann bob "one" >/dev/null
  migrate alpha

  # Re-enter the window the advisory describes: the config says per-team, and
  # the shared store still holds rows for this team.
  sqlite3 "$SHARED" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent','stray-1','alpha','ann','bob','still in shared',
           strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  [ "$(shared_rows alpha)" -eq 1 ]

  rm -f "$(store_of alpha)"
  run migrate alpha

  [ "$status" -ne 0 ]
  [[ "$output" =~ "does not exist" ]]
  [[ "$output" =~ "NOT been touched" ]]
  # The point of the test: the rows are still there.
  [ "$(shared_rows alpha)" -eq 1 ]
}

@test "migrate: a destination missing some of the shared rows is refused" {
  bash "$SCRIPTS/send.sh" alpha ann bob "one" >/dev/null
  migrate alpha

  # A row the destination never received — an interrupted copy, or one the
  # destination lost. Same count is not the test; this row is simply absent
  # there.
  sqlite3 "$SHARED" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent','never-copied','alpha','ann','bob','missing there',
           strftime('%Y-%m-%dT%H:%M:%SZ','now'));"

  run migrate alpha
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing rows" ]]
  [ "$(shared_rows alpha)" -eq 1 ]
}

# A destination that exists but cannot be read. Being unable to check is not
# the same as having checked: if an unreadable store counted as complete, the
# guard would pass in exactly the situation where it knows least.
@test "migrate: a destination that cannot be read is refused, not assumed complete" {
  bash "$SCRIPTS/send.sh" alpha ann bob "one" >/dev/null
  migrate alpha

  sqlite3 "$SHARED" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent','stray-1','alpha','ann','bob','still in shared',
           strftime('%Y-%m-%dT%H:%M:%SZ','now'));"

  # Present, non-empty, and not a database.
  local dest; dest="$(store_of alpha)"
  printf 'this is not a sqlite file' > "$dest"

  run migrate alpha
  [ "$status" -ne 0 ]
  [ "$(shared_rows alpha)" -eq 1 ]
}

# The scenario a key-only comparison waves through. After the destination is
# removed the config still says per-team, so the next write creates a NEW
# database there, AUTOINCREMENT restarts, and its first event takes seq 1 — a
# seq the shared store already used for something else. Comparing keys finds
# nothing missing and deletes real history.
@test "migrate: a destination whose keys collide with different content is refused" {
  bash "$SCRIPTS/send.sh" alpha ann bob "the original message" >/dev/null
  migrate alpha

  local dest; dest="$(store_of alpha)"
  local seq; seq=$(sqlite3 "$dest"     "SELECT seq FROM events WHERE type='message_sent' AND team='alpha' LIMIT 1;")

  # The shared store holds a row under the SAME seq, with different content —
  # what a recreated destination produces once numbering restarts.
  sqlite3 "$SHARED" "INSERT INTO events(seq,type,id,team,from_agent,to_agent,body,at)
    VALUES($seq,'message_sent','other-id','alpha','ann','bob','a different message',
           strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  [ "$(shared_rows alpha)" -eq 1 ]

  run migrate alpha
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing rows" ]]
  # The row is still there: same number, different content, not the same row.
  [ "$(shared_rows alpha)" -eq 1 ]
}

# Same class, other tables. messages.id is AUTOINCREMENT too, and a cursor's
# content is its position — a matching agent name says nothing about where that
# agent had read to. Each table is asserted separately because the comparison
# is written per table, and one of them getting it right hides the others.
@test "migrate: a message id reused for different content is refused" {
  # send.sh writes history to events; the messages table stays empty on this
  # path, so the row is placed on both sides directly. The table is still copied
  # and still deleted from the shared store, so it needs the same proof — and
  # measuring it required checking which tables actually carry rows rather than
  # assuming.
  bash "$SCRIPTS/send.sh" alpha ann bob "the original message" >/dev/null
  migrate alpha
  local dest; dest="$(store_of alpha)"

  sqlite3 "$dest" "INSERT INTO messages(id,team,from_agent,to_agent,body,created_at)
    VALUES(1,'alpha','ann','bob','what the destination holds',
           strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  sqlite3 "$SHARED" "INSERT INTO messages(id,team,from_agent,to_agent,body,created_at)
    VALUES(1,'alpha','ann','bob','a different body',
           strftime('%Y-%m-%dT%H:%M:%SZ','now'));"

  run migrate alpha
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing rows" ]]
  [ "$(sqlite3 "$SHARED" "SELECT COUNT(*) FROM messages WHERE team='alpha';")" -eq 1 ]
}

@test "migrate: a cursor at a different position is refused" {
  # ONLY the cursor differs. The containment check returns at the FIRST table
  # that is short, so a test that also leaves an events row behind never reaches
  # the cursor rule — the earlier version of this test passed while a mutation
  # removing that rule stayed green.
  bash "$SCRIPTS/send.sh" alpha ann bob "one" >/dev/null
  migrate alpha
  local dest; dest="$(store_of alpha)"

  # Same agent, present on both sides, at different positions. Comparing the
  # agent name alone calls this complete and deletes the shared cursor, silently
  # moving where that agent resumes reading.
  sqlite3 "$dest"   "INSERT OR REPLACE INTO read_cursors(team,agent,local_position)
    VALUES('alpha','ann',1);"
  sqlite3 "$SHARED" "INSERT OR REPLACE INTO read_cursors(team,agent,local_position)
    VALUES('alpha','ann',999);"

  # Nothing else is short, so a refusal here is about the cursor and not a
  # leftover event.
  [ "$(shared_rows alpha)" -eq 0 ]

  run migrate alpha
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing rows" ]]
  [ "$(sqlite3 "$SHARED"       "SELECT local_position FROM read_cursors WHERE team='alpha' AND agent='ann';")" -eq 999 ]
}

# The normal re-entry this guard must NOT break. After the config flips, new
# messages land in the destination, so it legitimately holds MORE than the
# shared store. A guard written as "the counts match" would refuse exactly the
# case it exists to complete.
@test "migrate: re-entry completes when the destination has more than the shared store" {
  bash "$SCRIPTS/send.sh" alpha ann bob "before the move" >/dev/null
  migrate alpha

  # Arrivals after the move: they go to the destination, as they do in life.
  bash "$SCRIPTS/send.sh" alpha ann bob "after the move" >/dev/null
  bash "$SCRIPTS/send.sh" alpha ann bob "also after" >/dev/null

  # And a leftover in the shared store, which is what re-entry is for. Copied
  # into the destination as an interrupted run would have done.
  local dest; dest="$(store_of alpha)"
  sqlite3 "$SHARED" "INSERT INTO events(seq,type,id,team,from_agent,to_agent,body,at)
    VALUES(9001,'message_sent','leftover','alpha','ann','bob','left behind',
           strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  sqlite3 "$dest" "INSERT INTO events(seq,type,id,team,from_agent,to_agent,body,at)
    VALUES(9001,'message_sent','leftover','alpha','ann','bob','left behind',
           strftime('%Y-%m-%dT%H:%M:%SZ','now'));"

  run migrate alpha
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already has its own store" ]]
  # The leftover is gone from shared, because the destination has it.
  [ "$(shared_rows alpha)" -eq 0 ]
}
