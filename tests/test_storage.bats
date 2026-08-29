#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# --- agmsg_db_path() resolution ---

@test "storage: default path resolves under the skill dir" {
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  [ "$(agmsg_db_path demo)" = "$TEST_SKILL_DIR/db/messages.db" ]
}

@test "storage: AGMSG_STORAGE_PATH overrides the storage dir" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  [ "$(agmsg_db_path demo)" = "$BATS_TEST_TMPDIR/store/messages.db" ]
}

@test "storage: trailing slash on the override is normalized" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store/"
  [ "$(agmsg_db_path demo)" = "$BATS_TEST_TMPDIR/store/messages.db" ]
}

# --- agmsg_db_path() Windows path conversion (#197) ---

@test "storage: agmsg_db_path applies cygpath -m on Windows so sqlite3.exe can open it (#197)" {
  # The native sqlite3.exe cannot open a Git Bash /c/... path; cygpath -m maps it
  # to the mixed C:/... form both the shell and sqlite3.exe accept. cygpath is
  # absent off Windows, so inject a shim on PATH to exercise the branch.
  local bindir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bindir"
  cat > "$bindir/cygpath" <<'SH'
#!/usr/bin/env bash
# Minimal stand-in: `cygpath -m /c/x` -> C:/x (BSD- and GNU-sed portable).
shift  # drop the -m flag
printf '%s\n' "$1" | sed -E 's#^/c/#C:/#'
SH
  chmod +x "$bindir/cygpath"
  run env PATH="$bindir:$PATH" AGMSG_STORAGE_PATH="/c/Users/test/db" \
    bash -c 'source "'"$SCRIPTS"'/lib/storage.sh"; agmsg_db_path demo'
  [ "$status" -eq 0 ]
  [ "$output" = "C:/Users/test/db/messages.db" ]
}

@test "storage: agmsg_db_path is a no-op without cygpath (off Windows)" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  # cygpath is absent on the test host, so the path is returned unchanged.
  [ "$(agmsg_db_path demo)" = "$BATS_TEST_TMPDIR/store/messages.db" ]
}

# --- init-db.sh honoring the override ---

@test "storage: init-db creates the db at the overridden path (and makes the dir)" {
  local custom="$BATS_TEST_TMPDIR/nested/store"
  [ ! -d "$custom" ]
  AGMSG_STORAGE_PATH="$custom" bash "$SCRIPTS/internal/init-db.sh"
  [ -f "$custom/messages.db" ]
}

# --- end-to-end roundtrip through the override ---

@test "storage: send and inbox share the overridden db" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-b
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  bash "$SCRIPTS/send.sh" testteam alice bob "hi via override"
  [ -f "$AGMSG_STORAGE_PATH/messages.db" ]

  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hi via override" ]]
}

@test "storage: stop-hook delivery works when the default db dir is absent but the override is populated" {
  local store="$BATS_TEST_TMPDIR/store"
  local project="/tmp/agmsg-storage-test-proj"

  # Register an agent so check-inbox can resolve identity via whoami.
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$project"
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/agmsg-storage-test-bob

  # A message addressed to alice lives only in the overridden store.
  AGMSG_STORAGE_PATH="$store" bash "$SCRIPTS/send.sh" testteam bob alice "via override store"

  # Simulate a clean install whose default skill db dir never existed.
  rm -rf "$TEST_SKILL_DIR/db"

  # Stop-hook delivery must still succeed (exit 0) and surface the message —
  # the cooldown marker now lives in run/, not the (absent) db dir.
  run bash -c "echo '{}' | AGMSG_STORAGE_PATH='$store' bash '$SCRIPTS/check-inbox.sh' claude-code '$project'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "via override store" ]]
}

@test "storage: default db is untouched when the override is set" {
  # The default store was initialized in setup; writing through an override
  # must not add rows to it.
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-b
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  bash "$SCRIPTS/send.sh" testteam alice bob "isolated"

  local default_count
  default_count=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$default_count" -eq 0 ]
}

@test "storage: agmsg_sqlite sets a busy timeout without polluting output" {
  # .timeout (not PRAGMA) so the timeout value is never echoed into results.
  source "$SCRIPTS/lib/storage.sh"
  run agmsg_sqlite ":memory:" "SELECT 'only-this';"
  [ "$status" -eq 0 ]
  [ "$output" = "only-this" ]
}

@test "storage: agmsg_sqlite emits a raw char(31) separator, not caret '^_' (#102)" {
  # sqlite3 >= 3.50 renders control bytes with caret notation by default, which
  # would turn the char(31) record separator into the two chars "^_" and break
  # the IFS=$'\x1f' field splitting in inbox/history/check-inbox + the watch
  # stream. agmsg_sqlite must pass -escape off so the byte stays raw. On older
  # sqlite3 the byte is raw anyway, so this holds on every supported version.
  source "$SCRIPTS/lib/storage.sh"
  run agmsg_sqlite ":memory:" "SELECT 'a'||char(31)||'b';"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q $'\x1f'
  ! printf '%s' "$output" | grep -q '\^_'
}

@test "storage: runtime lock replacement is compare-and-swap" {
  source "$SCRIPTS/lib/storage.sh"
  local resource="codex-dispatcher:test" owner

  owner="$(agmsg_runtime_lock_acquire "$resource" 111)"
  [ "$owner" = 111 ]
  owner="$(agmsg_runtime_lock_acquire "$resource" 222 111)"
  [ "$owner" = 222 ]
  # A contender that observed the old generation cannot delete its successor.
  owner="$(agmsg_runtime_lock_acquire "$resource" 333 111)"
  [ "$owner" = 222 ]
  agmsg_runtime_lock_verify "$resource" 222
  refute agmsg_runtime_lock_verify "$resource" 333
  agmsg_runtime_lock_release "$resource" 333
  agmsg_runtime_lock_verify "$resource" 222
  agmsg_runtime_lock_release "$resource" 222
  [ -z "$(agmsg_runtime_lock_owner "$resource")" ]
}

@test "storage: runtime lock initializes a fresh store before send" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/lock-first-store"
  source "$SCRIPTS/lib/storage.sh"

  [ "$(agmsg_runtime_lock_acquire codex-dispatcher:test 111)" = 111 ]
  bash "$SCRIPTS/send.sh" team alice bob "after lock init" --force
  [ "$(agmsg_sqlite "$(agmsg_db_path team)" "SELECT COUNT(*) FROM events WHERE type='message_sent' AND body = 'after lock init';")" = 1 ]
}

@test "send: concurrent fan-out to N recipients all land (no SQLITE_BUSY)" {
  # Without a busy_timeout, concurrent writers fail with SQLITE_BUSY(5) and the
  # sends silently drop. With the wrapper they wait and all land. See #114.
  local x
  for x in 1 2 3 4 5 6 7 8 9 10; do
    ( bash "$SCRIPTS/send.sh" team leader "tgt$x" "job $x" --force >/dev/null 2>&1 ) 3>&- &
  done
  wait
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
    "SELECT COUNT(*) FROM events WHERE type='message_sent' AND from_agent='leader';")
  [ "$n" -eq 10 ]
}

@test "send: concurrent fan-out to a FRESH (uninitialized) store all lands" {
  # No init-db first — every send races to initialize an override store that
  # doesn't exist yet. Without idempotent init + INSERT retry, the losers abort
  # on "already exists" / "no such table" and drop. See #114.
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/freshstore"
  local x
  for x in 1 2 3 4 5 6 7 8 9 10; do
    ( bash "$SCRIPTS/send.sh" team leader "tgt$x" "job $x" --force >/dev/null 2>&1 ) 3>&- &
  done
  wait
  local n
  n=$(sqlite3 "$AGMSG_STORAGE_PATH/messages.db" "SELECT COUNT(*) FROM events WHERE type='message_sent';")
  [ "$n" -eq 10 ]
}

@test "storage: the -escape probe is memoized, not re-run on every call (#462)" {
  # `$(_agmsg_escape_flag)` ran the probe in a subshell, so the memo it set was
  # discarded on exit and every agmsg_sqlite call spawned two sqlite3 processes
  # instead of one. Count real invocations through a counting shim.
  source "$SCRIPTS/lib/storage.sh"
  local count="$BATS_TEST_TMPDIR/sqlite-calls"
  : > "$count"
  local real; real="$(command -v sqlite3)"
  sqlite3() { echo call >> "$count"; "$real" "$@"; }

  local i
  for i in 1 2 3 4 5; do
    agmsg_sqlite ":memory:" "SELECT 1;" >/dev/null 2>&1 || true
  done

  # 5 queries + exactly one probe. Before the fix this was 10.
  [ "$(wc -l < "$count" | tr -d ' ')" -eq 6 ]
}

@test "storage: a memoized probe is inherited by command substitutions (#462)" {
  # Subshells inherit shell variables, so once the probe has run in this shell
  # every later $(agmsg_sqlite ...) reuses the memo instead of re-probing.
  # (A call made before any probe still probes inside its own subshell — the
  # memo is per shell, not per machine.)
  source "$SCRIPTS/lib/storage.sh"
  local count="$BATS_TEST_TMPDIR/sqlite-calls-sub"
  local real; real="$(command -v sqlite3)"
  sqlite3() { echo call >> "$count"; "$real" "$@"; }

  agmsg_sqlite ":memory:" "SELECT 1;" >/dev/null 2>&1 || true   # primes the memo
  : > "$count"

  local i out
  for i in 1 2 3 4 5; do
    out="$(agmsg_sqlite ":memory:" "SELECT 1;" 2>/dev/null)" || true
  done

  [ "$(wc -l < "$count" | tr -d ' ')" -eq 5 ]
}

# --- storage partition axis -----------------------------------------------------
#
# Which store a team uses is a per-team driver choice. `shared` is the default
# and is what programs outside agmsg read; `per-team` is what a team moves to
# when connecting requires it. The tests that matter here are the default (every
# team in one file, unchanged from before the axis existed) and the isolation a
# moved team gets.

# Put <team> on the per-team partition the way migrate-team-store.sh does, without
# copying anything: these tests are about resolution, not migration.
_use_per_team() {
  mkdir -p "$TEST_SKILL_DIR/teams/$1"
  printf '{"name":"%s","drivers":{"partition":"per-team"}}\n' "$1" \
    > "$TEST_SKILL_DIR/teams/$1/config.json"
}

@test "storage: every team shares one store by default" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/db" SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  # The partition external readers depend on. A team must not leave it by merely
  # existing — only by something that requires the move.
  [ "$(agmsg_db_path alpha)" = "$BATS_TEST_TMPDIR/db/messages.db" ]
  [ "$(agmsg_db_path bravo)" = "$BATS_TEST_TMPDIR/db/messages.db" ]
  [ "$(agmsg_db_path alpha)" = "$(_agmsg_runtime_db_path)" ]
}

@test "storage: a team on the per-team partition moves, and only that team" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/db" SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  _use_per_team alpha
  [ "$(agmsg_db_path alpha)" = "$BATS_TEST_TMPDIR/db/teams/alpha/messages.db" ]
  # Its neighbour is untouched — that is the whole point of choosing per team.
  [ "$(agmsg_db_path bravo)" = "$BATS_TEST_TMPDIR/db/messages.db" ]
  # And resolution does not stick: the memoized driver must not leak across teams.
  [ "$(agmsg_db_path alpha)" = "$BATS_TEST_TMPDIR/db/teams/alpha/messages.db" ]
}

@test "storage: an unknown partition is an error, not a fallback" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/db" SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  mkdir -p "$TEST_SKILL_DIR/teams/gamma"
  printf '{"name":"gamma","drivers":{"partition":"nope"}}\n' \
    > "$TEST_SKILL_DIR/teams/gamma/config.json"
  run agmsg_db_path gamma
  [ "$status" -ne 0 ]
  # Falling back to shared would read a real file holding other teams' rows.
  [[ ! "$output" =~ "messages.db" ]]
}

@test "storage: a selector that would escape the storage tree is refused" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/db" SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  local bad
  # A real store was found holding a project path as a team name, so this is
  # reachable from data, not only from a hostile argument.
  for bad in ".." "." "a/b" "/Users/someone/project"; do
    run agmsg_db_path "$bad"
    [ "$status" -ne 0 ]
    [[ ! "$output" =~ "$BATS_TEST_TMPDIR/db/teams/$bad" ]]
  done
}

@test "storage: a moved team's messages are not in the shared store" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/db" SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  _use_per_team alpha
  storage_init alpha >/dev/null
  storage_init bravo >/dev/null
  storage_send alpha ann bob "alpha-only" >/dev/null
  storage_send bravo cid bob "bravo-only" >/dev/null

  [[ "$(storage_list_unread alpha bob)" =~ "alpha-only" ]]
  [[ ! "$(storage_list_unread alpha bob)" =~ "bravo-only" ]]
  [[ "$(storage_list_unread bravo bob)" =~ "bravo-only" ]]
  [[ ! "$(storage_list_unread bravo bob)" =~ "alpha-only" ]]

  # Not just filtered on the way out — the bytes are in different files.
  refute grep -q "bravo-only" "$(agmsg_db_path alpha)"
  ! grep -q "alpha-only" "$(agmsg_db_path bravo)"
}

@test "storage: resolving a store without a selector is an error, not a default" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/db"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  run agmsg_db_path
  [ "$status" -ne 0 ]
  run agmsg_db_path ""
  [ "$status" -ne 0 ]
  # The runtime resolver is the one place a missing selector is correct: its
  # callers hold project-scoped state and have no team to name.
  run _agmsg_runtime_db_path
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "storage: no shipped script resolves a store without a selector" {
  # The point of requiring the selector is that no half-converted caller is left
  # to find. A bare call in production is exactly that, so it is swept for
  # rather than trusted.
  #
  # storage_init is here because watching only agmsg_db_path was not enough:
  # sqlite-sync.sh called storage_init with no team, which reached the resolver
  # one frame down. It failed to stderr while the command still succeeded, so
  # nothing went red until a test captured stderr and fed it to jq.
  local offenders
  # Bare only: the name closing a substitution, ending a line, or followed by a
  # redirect or pipe. A call WITH a selector is the thing we want, so it must
  # not match.
  # server/ is swept too, because its integration tests drive the client through
  # embedded bash. One selector-less storage_init lived there through two rounds
  # of this sweep: it is not a shell file, so watching scripts/ alone never saw
  # it, and it only failed once a store per team made the empty selector reach
  # the resolver. tests/ is deliberately excluded — a bare call there is how the
  # requirement itself is asserted.
  offenders="$(cd "$BATS_TEST_DIRNAME/.." && grep -rnE '(agmsg_db_path|storage_init) *(\)|\||>|$)' \
    scripts bin server 2>/dev/null | grep -v ':[0-9]*: *#' | grep -v 'storage_init()' || true)"
  [ -z "$offenders" ] || { echo "$offenders"; false; }
}

@test "storage: events.legacy_id is indexed, on a new store and on one that predates the column (#919)" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  agmsg_storage_load
  storage_init demo >/dev/null
  local db
  db=$(agmsg_db_path demo)
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND tbl_name='events' AND name='events_legacy';" | tr -d '\r')" -eq 1 ]
  # The lookup every reader makes per legacy row, and the projection makes per
  # message, is a search now -- not a scan of events.
  sqlite3 "$db" "EXPLAIN QUERY PLAN SELECT 1 FROM events e2 WHERE e2.legacy_id = 5;" | grep -q 'USING COVERING INDEX events_legacy\|USING INDEX events_legacy'
  # A store created before legacy_id existed: init adds the column first (the
  # ALTER that already ran for #689), then the index on it.
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/old"
  mkdir -p "$AGMSG_STORAGE_PATH"
  sqlite3 "$AGMSG_STORAGE_PATH/messages.db" "CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, id TEXT NOT NULL, team TEXT, from_agent TEXT, to_agent TEXT, body TEXT, msg_id TEXT, agent TEXT, at TEXT NOT NULL);"
  storage_init demo >/dev/null
  [ "$(sqlite3 "$AGMSG_STORAGE_PATH/messages.db" "PRAGMA table_info(events);" | grep -c legacy_id)" -eq 1 ]
  [ "$(sqlite3 "$AGMSG_STORAGE_PATH/messages.db" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='events_legacy';" | tr -d '\r')" -eq 1 ]
}

@test "storage: events.id is indexed, on a new store and on one that predates the index (#910)" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  agmsg_storage_load
  storage_init demo >/dev/null
  local db
  db=$(agmsg_db_path demo)
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND tbl_name='events' AND name='events_id';" | tr -d '\r')" -eq 1 ]
  # The lookup the sync import makes per imported message (FROM events
  # WHERE id=...) is a search now -- not a scan of every message body.
  sqlite3 "$db" "EXPLAIN QUERY PLAN SELECT seq FROM events WHERE id = 'x';" | grep -q 'USING COVERING INDEX events_id\|USING INDEX events_id'
  # A store from before this index existed picks it up on the next init. Such
  # a store also predates the schema-revision stamp (#1001), so the
  # simulation regresses both together -- a current stamp over a missing
  # index is a state no product path produces, and the fast path would
  # (correctly, per its contract) not heal it.
  sqlite3 "$db" "DROP INDEX events_id; PRAGMA user_version=0;"
  storage_init demo >/dev/null
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='events_id';" | tr -d '\r')" -eq 1 ]
}

# ---- #1001: storage_init fast path and the busy note ----

@test "storage: a store at the current schema revision skips init's write batch -- even while a writer holds the store (#1001)" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  agmsg_storage_load
  storage_init demo >/dev/null
  local db; db=$(agmsg_db_path demo)
  # The stamp landed.
  [ "$(sqlite3 "$db" "PRAGMA user_version;" | tr -d ' \r')" = 1 ]
  # Under a held write lock, the old init re-ran its write batch, waited the
  # full busy timeout and failed; the fast path READS the revision (WAL serves
  # reads beside a writer) and returns ok without touching the lock.
  ( printf 'BEGIN IMMEDIATE;\nSELECT 1;\n'; sleep 3; printf 'COMMIT;\n' ) | sqlite3 "$db" >/dev/null &
  local holder=$!
  sleep 0.5
  export AGMSG_BUSY_TIMEOUT=200
  run storage_init demo
  unset AGMSG_BUSY_TIMEOUT
  wait "$holder"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "storage: a revision mismatch runs the real init, and the stamp follows the schema (#1001)" {
  # The gate must swing BOTH ways: matching skips (above), and NOT matching
  # actually initializes -- the danger of a fast path is an old schema waved
  # through as new.
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  agmsg_storage_load
  storage_init demo >/dev/null
  local db; db=$(agmsg_db_path demo)
  # Regress the store: drop a piece of schema and the stamp together.
  sqlite3 "$db" "DROP INDEX events_id; PRAGMA user_version=0;"
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE name='events_id';" | tr -d ' \r')" = 0 ]
  run storage_init demo
  [ "$status" -eq 0 ]
  # The batch really ran: the schema piece is back, and so is the stamp.
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE name='events_id';" | tr -d ' \r')" = 1 ]
  [ "$(sqlite3 "$db" "PRAGMA user_version;" | tr -d ' \r')" = 1 ]
}

@test "storage: a failing init batch leaves the OLD revision, never a new stamp over a broken schema (#1001)" {
  # The stamp is the last statement of the same -bail transaction as the
  # schema. If anything before it fails, the transaction rolls back and the
  # store still says the old revision -- the fast path can then never treat
  # the broken store as current. Forced here with a trigger that aborts the
  # read-cursor adoption insert.
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  agmsg_storage_load
  mkdir -p "$AGMSG_STORAGE_PATH"
  local db; db=$(agmsg_db_path demo)
  sqlite3 "$db" "
    CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL,
      id TEXT NOT NULL, team TEXT, from_agent TEXT, to_agent TEXT, body TEXT,
      msg_id TEXT, agent TEXT, at TEXT NOT NULL, legacy_id INTEGER);
    CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, team TEXT NOT NULL,
      from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, body TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')), read_at TEXT);
    INSERT INTO messages(team,from_agent,to_agent,body) VALUES('demo','a','b','legacy row');
    CREATE TRIGGER boom BEFORE INSERT ON events WHEN NEW.type='message_read'
      BEGIN SELECT RAISE(ABORT,'forced mid-batch failure'); END;"
  run storage_init demo
  [ "$status" -eq 13 ]
  [ "$output" = runtime_error ]
  # No stamp: the store still says revision 0, so the next init tries again.
  [ "$(sqlite3 "$db" "PRAGMA user_version;" | tr -d ' \r')" = 0 ]
}

@test "storage: a call that gives up after the busy timeout says so on stderr, and a quiet store says nothing (#1001)" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  agmsg_storage_load
  storage_init demo >/dev/null
  local db; db=$(agmsg_db_path demo)
  # Quiet store: a write emits nothing.
  run --separate-stderr agmsg_sqlite "$db" "INSERT INTO storage_metadata(key,value) VALUES('t1','1');"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  # Contended store: the write waits the timeout, fails with SQLITE_BUSY, and
  # SAYS so -- "hung" becomes "waited and gave up".
  ( printf 'BEGIN IMMEDIATE;\nSELECT 1;\n'; sleep 3; printf 'COMMIT;\n' ) | sqlite3 "$db" >/dev/null &
  local holder=$!
  sleep 0.5
  export AGMSG_BUSY_TIMEOUT=200
  run --separate-stderr agmsg_sqlite "$db" "INSERT INTO storage_metadata(key,value) VALUES('t2','1');"
  unset AGMSG_BUSY_TIMEOUT
  wait "$holder"
  [ "$status" -eq 5 ]
  grep -Fq "the message store is busy" <<<"$stderr"
  grep -Fq "waited 200ms" <<<"$stderr"
}

@test "storage: init stamps only a store that is really in WAL -- a busy journal switch stops before the stamp (#1001)" {
  # The fast path's whole premise is WAL serving reads beside a writer. If
  # the journal-mode switch alone lost to a transient writer while the schema
  # transaction then succeeded, a rollback-journal store would be stamped
  # current and the fast path would never retry the switch -- minute-long
  # waits would return with a stamp saying all is well (review finding). So
  # init checks what the pragma ANSWERS and refuses to proceed on anything
  # but "wal".
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  agmsg_storage_load
  mkdir -p "$AGMSG_STORAGE_PATH"
  local db; db=$(agmsg_db_path demo)
  # A rollback-journal store, not yet initialized.
  sqlite3 "$db" "PRAGMA journal_mode=DELETE; CREATE TABLE seedmark(x);" >/dev/null
  [ "$(sqlite3 "$db" "PRAGMA user_version;" | tr -d ' \r')" = 0 ]
  # A writer holds the store: the journal switch comes back busy, and init
  # must stop THERE -- old stamp, old journal mode, an error worth seeing.
  ( printf 'BEGIN IMMEDIATE;\nSELECT 1;\n'; sleep 3; printf 'COMMIT;\n' ) | sqlite3 "$db" >/dev/null &
  local holder=$!
  sleep 0.5
  export AGMSG_BUSY_TIMEOUT=200
  run storage_init demo
  unset AGMSG_BUSY_TIMEOUT
  [ "$status" -eq 13 ]
  [ "$output" = runtime_error ]
  wait "$holder"
  [ "$(sqlite3 "$db" "PRAGMA user_version;" | tr -d ' \r')" = 0 ]
  [ "$(sqlite3 "$db" "PRAGMA journal_mode;" | tr -d ' \r')" = delete ]
  # The writer gone, the same init switches to WAL, initializes, and stamps.
  run storage_init demo
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ "$(sqlite3 "$db" "PRAGMA journal_mode;" | tr -d ' \r')" = wal ]
  [ "$(sqlite3 "$db" "PRAGMA user_version;" | tr -d ' \r')" = 1 ]
}
