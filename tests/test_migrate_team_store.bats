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

row_count() { sqlite3 "$1" "SELECT COUNT(*) FROM $2;" | tr -d '\r'; }

# Storage classes actually present in a column, one per line, deduplicated.
stored_types() {
  sqlite3 "$1" "SELECT DISTINCT typeof($3) FROM $2;" | tr -d '\r'
}

# What this test alone protects: the storage class of events.seq.
#
# The containment check compares events with all-column EXCEPT. That catches a
# row whose seq differs — but not a seq that stopped being a number, because
# if the column took a text affinity BOTH stores store text and the two sides
# match. A green EXCEPT then means "identical", not "correct", and the shared
# rows are deleted on the strength of it.
#
# The values here come from send.sh, so this is a statement about the
# product's own write path, not about a literal this test inserted. That
# distinction is the whole point (tl ruling): a typeof() check on a value the
# test wrote proves the test can write an integer.
#
# read_cursors is NOT here. A text AFFINITY on that column turns the 1005/999
# re-entry test below red, so checking for that would be a second copy of an
# existing catch. Its storage class is looked at by no test in this
# repository — see the note on that test for why the gap is worse than
# undetected.
#
# DETECTION, not enforcement: this observes the rows that exist, it does not
# stop a bad one being written. Enforcing needs a schema change — a STRICT
# table, or CHECK(typeof(seq)='integer') — and a migration with it.
@test "migrate: the seq the containment check compares is stored as an integer" {
  # Asserted where each value actually lives, not all at one moment: a
  # migration empties the shared store of the team that left, so checking both
  # stores at the end reads an empty table on one side and passes vacuously.
  # That is what the first version of this test did; the row counts refuse it.
  bash "$SCRIPTS/send.sh" alpha ann bob "one" >/dev/null

  [ "$(row_count "$SHARED" events)" -ge 1 ]
  [ "$(stored_types "$SHARED" events seq)" = "integer" ]

  migrate alpha
  local dest; dest="$(store_of alpha)"

  [ "$(row_count "$dest" events)" -ge 1 ]
  [ "$(stored_types "$dest" events seq)" = "integer" ]
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
  # The row is placed on both sides directly, at an id well clear of the ones a
  # send allocates. That distance is load-bearing now: a send writes the legacy
  # table too (#689), so this fixture's id is no longer free by default and a
  # low one collides with the mirror rather than testing anything. The comment
  # that used to sit here said the messages table stays empty on this path,
  # which was true when it was written and is not now.
  bash "$SCRIPTS/send.sh" alpha ann bob "the original message" >/dev/null
  migrate alpha
  local dest; dest="$(store_of alpha)"

  # ONE timestamp, used by both sides. The containment check compares
  # created_at, so evaluating strftime('now') twice let the two rows differ by a
  # second -- and then `refused` was satisfied by the timestamps rather than by
  # the body. Measured: with both bodies made identical, this test failed when
  # the two inserts shared a second and PASSED when they straddled one. It was
  # green either way, so nothing ever asked to look at it (#723).
  local at; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$dest" "INSERT INTO messages(id,team,from_agent,to_agent,body,created_at)
    VALUES(9001,'alpha','ann','bob','what the destination holds','$at');"
  sqlite3 "$SHARED" "INSERT INTO messages(id,team,from_agent,to_agent,body,created_at)
    VALUES(9001,'alpha','ann','bob','a different body','$at');"

  run migrate alpha
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing rows" ]]
  [ "$(sqlite3 "$SHARED" "SELECT COUNT(*) FROM messages WHERE team='alpha';")" -eq 1 ]
}

# The negative control for the test above, and the reason it cannot quietly
# stop meaning anything again.
#
# The test above is green whether it refuses for the right reason or the wrong
# one, so nothing in it can report that the fixture drifted. This one is red the
# moment the two sides stop being identical -- which is exactly what a second
# strftime('now') would do. Reintroduce one and this fails; the test above would
# not (#723).
#
# It is also the behaviour re-entry depends on: a row already carried across is
# not a conflict, or an interrupted run could never be resumed.
@test "migrate: a message id reused for the SAME content is not refused" {
  bash "$SCRIPTS/send.sh" alpha ann bob "the original message" >/dev/null
  migrate alpha
  local dest; dest="$(store_of alpha)"

  # Byte-identical on both sides, timestamp included.
  local at; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$dest" "INSERT INTO messages(id,team,from_agent,to_agent,body,created_at)
    VALUES(9001,'alpha','ann','bob','what both sides hold','$at');"
  sqlite3 "$SHARED" "INSERT INTO messages(id,team,from_agent,to_agent,body,created_at)
    VALUES(9001,'alpha','ann','bob','what both sides hold','$at');"

  run migrate alpha
  [ "$status" -eq 0 ]
  # The shared copy is gone, because the destination already had it.
  [ "$(sqlite3 "$SHARED" "SELECT COUNT(*) FROM messages WHERE team='alpha';")" -eq 0 ]
  # And the destination still holds it. Without this, a regression that removed
  # the rows from BOTH stores would satisfy everything above -- status 0, shared
  # empty -- while destroying the data the move exists to preserve. Found in
  # review; the shared-side count alone cannot tell "carried across" from "gone".
  #
  # Every compared column, not COUNT(*): a count survives the row being replaced
  # with different content, which is the failure the test above is about.
  [ "$(sqlite3 "$dest" "SELECT id||'|'||team||'|'||from_agent||'|'||to_agent||'|'||body||'|'||created_at||'|'||COALESCE(read_at,'-') FROM messages WHERE id=9001;")" = "9001|alpha|ann|bob|what both sides hold|$at|-" ]
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

# A cursor that moved on after the move. Reads go to the destination once the
# config flips, so its cursor legitimately runs AHEAD of the shared copy, which
# stays frozen at the moment of the move. An identity comparison refuses this —
# and it happens as soon as anyone reads once, which in a recovery window that
# stays open is close to always.
@test "migrate: a cursor that advanced in the destination does not block re-entry" {
  bash "$SCRIPTS/send.sh" alpha ann bob "one" >/dev/null
  migrate alpha
  local dest; dest="$(store_of alpha)"

  # 1005 and 999 are chosen: as text, '1005' sorts BEFORE '999', so a
  # comparison that became textual reads this advance as a retreat and
  # refuses. Confirmed by mutation — declaring local_position TEXT turns this
  # test red.
  #
  # What this test guards is that the ORDER is compared numerically. It does
  # not look at the storage class of local_position, and NO TEST IN THIS
  # REPOSITORY does — stated plainly because the alternative is a reader
  # assuming some other test has it.
  #
  # The gap is worse than undetected. A text VALUE in a column still declared
  # INTEGER is something sqlite permits, and it inverts the guard: `'abc' < 5`
  # is false, so a text cursor in the destination reads as "not behind", the
  # row is called present, and the shared cursor is deleted. Closing it means
  # checking the values inside the guard itself — a change to
  # migrate-team-store.sh, not to this file.
  sqlite3 "$dest"   "INSERT OR REPLACE INTO read_cursors(team,agent,local_position)
    VALUES('alpha','ann',1005);"
  sqlite3 "$SHARED" "INSERT OR REPLACE INTO read_cursors(team,agent,local_position)
    VALUES('alpha','ann',999);"

  run migrate alpha
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already has its own store" ]]
  # The stale shared cursor is cleared; the destination keeps the further one.
  [ "$(sqlite3 "$SHARED" \
      "SELECT COUNT(*) FROM read_cursors WHERE team='alpha';")" -eq 0 ]
  [ "$(sqlite3 "$dest" \
      "SELECT local_position FROM read_cursors WHERE team='alpha' AND agent='ann';")" -eq 1005 ]
}

# A cursor the destination never received. Deleting the shared copy would lose
# where that agent had read to entirely — they would resume from the start and
# re-read everything, or from zero and appear to have read nothing. Absent is
# not "far enough along"; it is no information at all.
@test "migrate: a cursor absent from the destination is refused" {
  bash "$SCRIPTS/send.sh" alpha ann bob "one" >/dev/null
  migrate alpha
  local dest; dest="$(store_of alpha)"

  # Only in the shared store. Nothing else is short, so a refusal is about this.
  sqlite3 "$dest"   "DELETE FROM read_cursors WHERE team='alpha' AND agent='ann';"
  sqlite3 "$SHARED" "INSERT OR REPLACE INTO read_cursors(team,agent,local_position)
    VALUES('alpha','ann',42);"
  [ "$(shared_rows alpha)" -eq 0 ]

  run migrate alpha
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing rows" ]]
  [ "$(sqlite3 "$SHARED" \
      "SELECT local_position FROM read_cursors WHERE team='alpha' AND agent='ann';")" -eq 42 ]
}

# A cursor that is not a number cannot be compared, so it is not proof.
#
# This is the case the ordering guard is blind to on its own: sqlite orders
# integers before text, so `'abc' < 5` is FALSE. A text cursor in the
# destination answers "not behind" to the very comparison meant to catch being
# behind — the check reports nothing missing, and the shared cursor is deleted
# with the rest of the team's rows. The agent resumes from wherever the
# damaged value puts them, and their real read position is gone.
#
# Written as "the shared cursor survives", because survival is the point. A
# guard that refused but deleted anyway would pass a message-only assertion.
#
# How a non-integer gets into the column is NOT established. sqlite permits it
# in a column declared INTEGER, and this is a defence against an entry point
# that has not been found, not a fix for a reproduced one.
@test "migrate: a cursor that is not an integer is refused, and the shared copy survives" {
  bash "$SCRIPTS/send.sh" alpha ann bob "one" >/dev/null
  migrate alpha
  local dest; dest="$(store_of alpha)"

  # The destination is genuinely AHEAD in every honest reading — 'abc' is not
  # a position at all. Under the old comparison this row answered "not
  # behind", so nothing was reported and the shared row was deleted.
  sqlite3 "$dest"   "INSERT OR REPLACE INTO read_cursors(team,agent,local_position)
    VALUES('alpha','ann','abc');"
  sqlite3 "$SHARED" "INSERT OR REPLACE INTO read_cursors(team,agent,local_position)
    VALUES('alpha','ann',42);"
  # The premise this test rests on, measured rather than assumed: the column
  # is declared INTEGER and sqlite stored text in it anyway.
  [ "$(sqlite3 "$dest" "SELECT typeof(local_position) FROM read_cursors
        WHERE team='alpha' AND agent='ann';")" = "text" ]

  # Nothing else is short, so a refusal here is about the cursor.
  [ "$(shared_rows alpha)" -eq 0 ]

  run migrate alpha
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing rows" ]]
  # The whole point: the position the agent had actually reached is still here.
  [ "$(sqlite3 "$SHARED" \
      "SELECT local_position FROM read_cursors WHERE team='alpha' AND agent='ann';")" -eq 42 ]
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
  # ONE timestamp, used by both sides -- this is meant to be the SAME row on
  # both, and the containment check compares `at`. Evaluating strftime('now')
  # once per statement made it two different rows whenever the pair straddled a
  # second, which is the intermittent `missing rows (events)` CI saw. Forcing
  # the boundary with a sleep reproduces that message exactly (#723).
  local at; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$SHARED" "INSERT INTO events(seq,type,id,team,from_agent,to_agent,body,at)
    VALUES(9001,'message_sent','leftover','alpha','ann','bob','left behind','$at');"
  sqlite3 "$dest" "INSERT INTO events(seq,type,id,team,from_agent,to_agent,body,at)
    VALUES(9001,'message_sent','leftover','alpha','ann','bob','left behind','$at');"

  run migrate alpha
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already has its own store" ]]
  # The leftover is gone from shared, because the destination has it.
  [ "$(shared_rows alpha)" -eq 0 ]
}

# --- #695: a copied cursor can land ahead of the destination's own sequence -

# A read cursor in the shared store is a position in the shared store's GLOBAL
# events.seq space -- every team's traffic advances it, not just the one being
# migrated. seq/id are copied verbatim (by design: renumbering would move
# every cursor), but sqlite_sequence is deliberately NOT copied -- the comment
# above the schema copy says the AUTOINCREMENT columns "bring it back on their
# own first insert." That first insert only sees THIS team's rows, so the
# destination's high-water becomes MAX(this team's own copied seqs) -- which
# can be far below a cursor that reflects every team's combined traffic. A new
# message then receives a seq below the cursor and is permanently invisible.
#
# Production shape (#695): radmin-oss's cursor was 13203 (the shared store's
# all-teams high-water); its own migrated events topped out at 11. Reproduced
# here at a smaller scale with the same relationship: OTHER teams' traffic
# pushes the shared high-water past what the migrating team's own events will
# ever reach.
@test "migrate: a new per-team message is deliverable after migration when the copied cursor exceeds the team's own event range (#695)" {
  # alpha's own message goes FIRST, so its copied seq is the low end of the
  # shared store's range -- beta's traffic afterward pushes the GLOBAL
  # high-water past it, exactly the "other teams advance the shared sequence
  # beyond the migrating team's own maximum" shape the issue asks for. (Doing
  # this the other way around -- alpha last -- makes alpha's own event BE the
  # current high-water, which accidentally satisfies the invariant even
  # without the fix and proves nothing; caught by this test passing before
  # the fix was applied, which is what sent this comment back to explain it.)
  bash "$SCRIPTS/send.sh" alpha ann bob "alpha message 1" >/dev/null
  bash "$SCRIPTS/send.sh" beta ann bob "beta message 1" >/dev/null
  bash "$SCRIPTS/send.sh" beta ann bob "beta message 2" >/dev/null
  bash "$SCRIPTS/send.sh" beta ann bob "beta message 3" >/dev/null

  # bob's read cursor for alpha, set to the shared store's CURRENT global
  # high-water -- a legitimate value in that space, since it is not scoped to
  # one team.
  local shared_highwater
  shared_highwater="$(sqlite3 "$SHARED" "SELECT seq FROM sqlite_sequence WHERE name='events';")"
  sqlite3 "$SHARED" "INSERT OR REPLACE INTO read_cursors(team,agent,local_position)
    VALUES('alpha','bob',$shared_highwater);"

  migrate alpha
  local dest; dest="$(store_of alpha)"

  # 1. The destination's own AUTOINCREMENT high-water is not behind the
  #    copied cursor -- this is the invariant the issue names directly.
  local dest_tip dest_cursor
  dest_tip="$(sqlite3 "$dest" "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0);")"
  dest_cursor="$(sqlite3 "$dest" "SELECT local_position FROM read_cursors WHERE team='alpha' AND agent='bob';")"
  [ "$dest_tip" -ge "$dest_cursor" ]

  bash "$SCRIPTS/send.sh" alpha ann bob "sent after migration" >/dev/null

  # 2. The new message's own seq is above the recipient's cursor.
  local new_seq
  new_seq="$(sqlite3 "$dest" "SELECT seq FROM events WHERE type='message_sent' AND team='alpha' AND body='sent after migration';")"
  [ "$new_seq" -gt "$dest_cursor" ]

  # 3 + 4. Through the REAL contract functions, not just checking that the
  # numbers line up -- proving the message is actually deliverable. Matching
  # numbers with nothing delivered is exactly the shape production spent
  # hours chasing tonight.
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load

  run storage_list_unread alpha bob
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent after migration"* ]]

  local after; after="$(storage_watch_after "$dest_cursor" alpha:bob)"
  [[ "$after" == *"sent after migration"* ]]
  [[ "$after" == *'"type":"cursor"'* ]]
}

# Requirement 5 from the issue: the same properties when the target team has
# NO event rows before migration. This is the sharper case -- with zero rows
# copied, sqlite never creates a sqlite_sequence row for 'events' at all (only
# the first AUTOINCREMENT insert does that), so there is no existing row to
# raise; one has to be created from nothing.
@test "migrate: the empty-event case also gets a destination high-water that is not behind the copied cursor (#695)" {
  bash "$SCRIPTS/join.sh" gamma carol claude-code /tmp/gamma-carol >/dev/null
  bash "$SCRIPTS/join.sh" gamma dave  claude-code /tmp/gamma-dave  >/dev/null
  bash "$SCRIPTS/send.sh" beta ann bob "beta message 1" >/dev/null
  bash "$SCRIPTS/send.sh" beta ann bob "beta message 2" >/dev/null

  local shared_highwater
  shared_highwater="$(sqlite3 "$SHARED" "SELECT seq FROM sqlite_sequence WHERE name='events';")"
  sqlite3 "$SHARED" "INSERT OR REPLACE INTO read_cursors(team,agent,local_position)
    VALUES('gamma','dave',$shared_highwater);"
  [ "$(shared_rows gamma)" -eq 0 ]

  migrate gamma
  local dest; dest="$(store_of gamma)"

  local dest_tip dest_cursor
  dest_tip="$(sqlite3 "$dest" "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0);")"
  dest_cursor="$(sqlite3 "$dest" "SELECT local_position FROM read_cursors WHERE team='gamma' AND agent='dave';")"
  [ "$dest_tip" -ge "$dest_cursor" ]

  bash "$SCRIPTS/send.sh" gamma carol dave "first message ever, after migration" >/dev/null

  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  run storage_list_unread gamma dave
  [ "$status" -eq 0 ]
  [[ "$output" == *"first message ever, after migration"* ]]
}

# A review of #696: the fix above feeds MAX(local_position) straight into
# sqlite_sequence.seq, an AUTOINCREMENT-authority column -- not a data column
# like the ones the re-entry guard above already protects. SQLite ranks TEXT
# above every INTEGER in its default comparison, so a single non-integer
# cursor among this team's rows can make MAX() pick the damaged value over
# any real one, corrupting how every future seq gets assigned on this store
# -- not merely carrying a bad value forward unread the way the OLD (pre-#695)
# first-time path already could.
#
# The existing "not an integer is refused" test above covers RE-ENTRY only
# (it migrates alpha successfully first, then corrupts the DESTINATION to
# test _missing_from_dest). This is the gap named: the FIRST-TIME path
# never validated source cursor types at all before this fix started writing
# them into sqlite_sequence. Reproduced by corrupting the SHARED cursor
# BEFORE ever migrating, so the very first attempt is what has to refuse.
@test "migrate: a non-integer source cursor refuses the FIRST migration attempt, before anything is written to the destination (#695 follow-up)" {
  bash "$SCRIPTS/send.sh" alpha ann bob "one" >/dev/null
  sqlite3 "$SHARED" "INSERT OR REPLACE INTO read_cursors(team,agent,local_position)
    VALUES('alpha','ann','abc');"
  # The premise, measured rather than assumed: the column is declared
  # INTEGER and sqlite stored text in it anyway.
  [ "$(sqlite3 "$SHARED" "SELECT typeof(local_position) FROM read_cursors
        WHERE team='alpha' AND agent='ann';")" = "text" ]

  run migrate alpha
  [ "$status" -ne 0 ]
  [[ "$output" =~ "non-integer read cursor" ]]

  # Refused, not repaired: the malformed value is still exactly what it was
  # -- silently ignoring it in MAX() would have erased the evidence a bad
  # cursor exists, which is explicitly not acceptable here (review).
  [ "$(sqlite3 "$SHARED" "SELECT local_position FROM read_cursors
        WHERE team='alpha' AND agent='ann';")" = "abc" ]
  # Nothing moved: the shared store still has the team's row, and no
  # destination file was created at all -- the guard runs before $DEST is
  # even touched.
  [ "$(shared_rows alpha)" -eq 1 ]
  # The literal expected per-team path, not store_of: with the migration
  # refused, alpha's partition never flipped away from "shared", so
  # store_of would resolve back to $SHARED itself (which of course exists)
  # rather than say anything about whether a per-team file got created.
  [ ! -e "$TEST_SKILL_DIR/db/teams/alpha/messages.db" ]
}

@test "migrate: the link between an event and its legacy row survives the move (#710)" {
  # #689 records the legacy rowid on the event so that the two rows other code
  # UNIONs -- the event log and the legacy messages table -- can be recognised
  # as one message. The copy here carries whole rows, so it has to carry that
  # column too: without it every moved message arrives unlinked, and the same
  # two readers #689 measured list it twice again. The projection in
  # sqlite-sync then pushes a second copy of each one to the server, which is
  # how it reaches the other machine.
  bash "$SCRIPTS/send.sh" alpha ann bob "one message" >/dev/null
  migrate alpha

  run bash "$SCRIPTS/history.sh" alpha bob
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'one message')" -eq 1 ]

  # The column that makes that true. Asserted separately because the reader
  # above can be right for the wrong reason -- a dedupe that guessed from the
  # body would pass it and still leave the projection with nothing to match.
  db="$(store_of alpha)"
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events
        WHERE team='alpha' AND type='message_sent' AND legacy_id IS NULL;" | tr -d '\r')" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT legacy_id FROM events
        WHERE team='alpha' AND type='message_sent';" | tr -d '\r')" \
    = "$(sqlite3 "$db" "SELECT id FROM messages WHERE team='alpha';" | tr -d '\r')" ]
}
