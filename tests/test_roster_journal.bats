#!/usr/bin/env bats

load test_helper

UUID7_RE='^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

setup() {
  setup_test_env
}

teardown() {
  # NOTHING THIS FILE STARTS MAY OUTLIVE IT.
  #
  # Several cases here are driven by a fake node that ignores TERM, and one is
  # deliberately a process the driver must NOT be able to stop. When such a
  # case fails -- or when someone runs a mutation against it -- the fixture is
  # left running. That is the shape `scripts/lib/close-fds.sh` and
  # `tests/test_spawn_fd_guard.bats` exist for: a leaked process can hold a
  # shard open long after every case has reported. Five were found alive on
  # this machine at once while this file was being written.
  #
  # Matched on TEST_SKILL_DIR, which `mktemp -d` makes fresh for every single
  # case, so this can only ever name processes this case started -- never
  # another suite's, and never another worktree's.
  if [ -n "${TEST_SKILL_DIR:-}" ]; then
    local stragglers
    stragglers="$(pgrep -f "$TEST_SKILL_DIR" 2>/dev/null || true)"
    if [ -n "$stragglers" ]; then
      # shellcheck disable=SC2086
      kill $stragglers 2>/dev/null || true
      sleep 1
      # shellcheck disable=SC2086
      kill -9 $stragglers 2>/dev/null || true
    fi
  fi
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

# On Windows, sqlite3.exe is a native binary that cannot open an MSYS path like
# /tmp/x/roster.jsonl. agmsg_sql_readfile_path runs `cygpath -w` first, then
# escapes. A value escaper doubles quotes and converts nothing, so readfile()
# returns NULL, the projection comes back empty, and join.sh exits 1 right after
# printing that it created the team -- with nothing on stderr, because an
# unopenable file and an empty file are the same answer at every layer (#669).
#
# cygpath does not exist off Windows, so the conversion has no observable effect
# here. Stub an IDENTITY cygpath instead: it returns its argument unchanged, so
# behaviour on this platform is exactly what it was, and it records what it was
# asked to convert. The record is the assertion -- which paths took the
# converted route, rather than whether this particular platform happened to
# need it.
# The first version of this test recorded what cygpath was asked to convert and
# asserted the journal appeared in that record. It did not discriminate: the
# readability guard that ships with the fix converts the same two paths, so
# putting the value escaper back in the QUERY left the test green. Measured --
# the mutation was not caught.
#
# So read the statement instead. cygpath returns a marked path and sqlite3 is
# captured rather than run, which makes "the projection query holds a converted
# path" a thing this test can see directly, on any platform.
_capture_sql() {   # $1 = stub dir, $2 = capture file
  mkdir -p "$1"
  # Last argument is the payload in both cases (`cygpath -w <path>`,
  # `sqlite3 :memory: <sql>`); read it with a loop rather than ${@: -1} so
  # bash 3.2 handles it too.
  cat > "$1/cygpath" <<EOS
#!/usr/bin/env bash
last=""
for a in "\$@"; do last="\$a"; done
printf 'WINPATH>%s' "\$last"
EOS
  # One line per STATEMENT, not per line of SQL. These statements are many lines
  # long, so appending them verbatim would let a later grep match one line of a
  # statement and miss the rest of it -- which is what the first attempt at this
  # assertion did.
  cat > "$1/sqlite3" <<EOS
#!/usr/bin/env bash
sql=""
for a in "\$@"; do sql="\$a"; done
printf '%s' "\$sql" | tr '\n' ' ' >> "$2"
printf '\n' >> "$2"
case "\$sql" in
  *"IS NOT NULL"*) printf '1\n' ;;    # readability guard: yes, sqlite can open it
  *)               printf '{}\n' ;;   # anything else: a harmless empty object
esac
EOS
  chmod +x "$1/cygpath" "$1/sqlite3"
}

@test "roster journal: the projection query itself reads a converted path (#669)" {
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"

  local bin="$BATS_TEST_TMPDIR/bin" cap="$BATS_TEST_TMPDIR/sql.txt"
  _capture_sql "$bin" "$cap"
  PATH="$bin:$PATH" bash -c '
    source "'"$SCRIPTS"'/lib/roster-journal.sh"
    agmsg_roster_project_config "'"$team_dir"'" "'"$team_dir"'/config.json"
  ' || true

  # The projection is the statement that rebuilds $.agents and
  # $.retired_members; the guard issues a different one, and matching on "any
  # statement" is how the previous version of this test lost its teeth.
  local proj
  proj="$(grep 'retired_members' "$cap" | head -1)"
  [ -n "$proj" ]
  # Both files, because converting the journal and leaving the team config on
  # the old route is a state this module was actually in.
  [[ "$proj" == *"readfile('WINPATH>"*"roster.jsonl')"* ]]
  [[ "$proj" == *"readfile('WINPATH>"*"config.json')"* ]]
}

@test "roster journal: a file sqlite cannot read is not answered as an empty roster (#669)" {
  # The other half of #669. readfile() returns NULL for a path it cannot open
  # and an empty blob for an empty file, and every projection built on it turns
  # both into no rows -- so the caller returned 1 with nothing on stderr and the
  # operator saw a success line followed by silence.
  #
  # Unreadability is produced here with a mode bit rather than a path form,
  # because the path form only misbehaves on Windows. The code path is the same
  # one: sqlite is handed a path it cannot open.
  if [ "$(id -u)" = "0" ]; then
    skip "root reads through the mode bits this is about"
  fi
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local journal="$TEST_SKILL_DIR/teams/demo/roster.jsonl"
  chmod 000 "$journal"

  run bash "$SCRIPTS/join.sh" demo bob claude-code /tmp/b
  chmod 644 "$journal"

  [ "$status" -ne 0 ]
  # It must say what it could not read, and name it.
  [[ "$output" == *"could not read"* ]]
  [[ "$output" == *"roster.jsonl"* ]]

  # And it must not name a cause it did not establish. This failure is a mode
  # bit; the earlier wording said "the file is present, so this is the path
  # form, not the file", which is exactly wrong here and would send a reader
  # after cygpath for a chmod. The four assertions above all held under that
  # wording, so none of them was keeping the promise -- these two do.
  [[ "$output" == *"permissions"* ]]
  [[ "$output" != *"not the file"* ]]
}

@test "roster journal: an empty projection from readable files says so, and does not blame the path (#669)" {
  # The third answer. Naming a path that could not be read is right only when a
  # path could not be read; saying it about a file that WAS read sends the
  # reader after the path form for a defect in the journal's contents. Before
  # this, all three answers were the same silent `return 1`.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  printf 'not json at all\n' > "$team_dir/roster.jsonl"

  run bash -c '. "$1/lib/roster-journal.sh"; agmsg_roster_project_config "$2" "$3"' _ \
    "$SCRIPTS" "$team_dir" "$team_dir/config.json"

  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no config"* ]]
  [[ "$output" != *"could not read"* ]]
}

@test "roster journal: an unreadable journal does not replace the roster with an empty one (#669)" {
  # The reason readability is asked BEFORE the query rather than after an empty
  # result. With the journal unreadable and the config fine, the projection does
  # not come back empty: readfile(journal) is NULL, the fold sees no events, and
  # json_set() builds a perfectly valid config with an EMPTY roster. Committing
  # that would delete every member -- from a file the process could not read.
  #
  # A check that only fires on an empty result cannot see this one. That is the
  # whole point of the test: the dangerous answer is the believable one.
  #
  # This is a GUARD, not a repair -- the check was already in the right place
  # when this test was written, and the commit that added the test claimed
  # otherwise. What the test pins is the position of the check, which is easy to
  # "optimise" into the cheaper shape and lose. Measured against a version whose
  # check runs only after an empty result:
  #
  #   before  agents={"alice":{"member_id":"019f...","registrations":[...]}}
  #   chmod 000 roster.jsonl; project
  #     status=0, no output on stdout or stderr
  #   after   agents={}
  #
  # It reports success. That is what this test exists to keep out.
  if [ "$(id -u)" = "0" ]; then
    skip "root reads through the mode bits this is about"
  fi
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo" config="$TEST_SKILL_DIR/teams/demo/config.json"
  local before
  before="$(config_field "$config" '$.agents.alice.member_id')"
  [ -n "$before" ]

  chmod 000 "$team_dir/roster.jsonl"
  run bash -c '. "$1/lib/roster-journal.sh"; agmsg_roster_project_config "$2" "$3"' _ \
    "$SCRIPTS" "$team_dir" "$config"
  chmod 644 "$team_dir/roster.jsonl"

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read"* ]]
  # And the roster is exactly as it was.
  [ "$(config_field "$config" '$.agents.alice.member_id')" = "$before" ]
}

@test "roster sync bounds a local child that never finishes, and releases the lock (#821)" {
  skip_on_windows "POSIX signal delivery is not supported by this test"
  # A child that neither runs to completion nor lets the shell exit.
  #
  # NOT the Windows failure reported on #817: that one is explained by a
  # holder-metadata write whose failure is swallowed, and by the parent
  # SIGKILLing this driver after a stdin error — neither of which is this, and
  # neither of which has been reproduced. What is deterministic here is the
  # property #821 states, and nothing beyond it.
  #
  # Release used to be the
  # EXIT trap alone, which is sound when this shell reaches its own exit — a
  # child that fails to launch or exits non-zero still gets there — and not
  # sound here. The shell waits, the trap never runs, and `.config.lock` is
  # held by a live process that will never finish. The next start then fails on
  # `File exists`, and the team is unusable.
  #
  # The fake IGNORES TERM, so the grace period and the KILL are exercised too;
  # a fake that exits on TERM would leave the harder half of the path untested.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id fake status=0
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  source "$SCRIPTS/lib/roster-journal.sh"
  agmsg_roster_append_left "$team_dir" "$member_id" alice "2026-01-01T00:00:00Z"

  fake="$TEST_SKILL_DIR/fake-node-unkillable"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
while :; do sleep 1; done
EOF
  chmod +x "$fake"

  run env AGMSG_SYNC_NODE_BIN="$fake" AGMSG_ROSTER_SYNC_TIMEOUT_S=2 \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  # A bounded FAILURE, not a hang and not a success.
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'did not finish within'
  # And the lock is gone, which is the whole point: the next start must not
  # meet `.config.lock: File exists` left by a process that is no longer there.
  [ ! -d "$team_dir/.config.lock" ]
  # The child is gone as well — released after the reap, never beside a live
  # writer.
  refute pgrep -f "$fake"
}

# A directory that shadows one command with a failing stub, for the two cases
# below. Only the named command is replaced; everything else still resolves
# normally, so the driver is exercised rather than a crippled shell.
_shim_failing() {
  local name="$1" dir="$TEST_SKILL_DIR/shim-$name"
  mkdir -p "$dir"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$dir/$name"
  chmod +x "$dir/$name"
  printf '%s' "$dir"
}

@test "roster sync is still bounded when no FIFO can be made (#821)" {
  skip_on_windows "POSIX signal delivery is not supported by this test"
  # THE PATH THAT USED TO DROP THE PROPERTY. When `mkfifo` failed, this fell
  # back to a foreground call with no ceiling and said `running without a time
  # bound` — which is the state #821 exists to forbid, reached by the code
  # meant to hold it. Three reviewers raised it independently.
  #
  # A FIFO is only the cheaper way to wait. Without one the sentinel is polled,
  # and the ceiling is the same. This case is the difference between the two
  # readings of "the instrument could not be built".
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id fake shim
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  source "$SCRIPTS/lib/roster-journal.sh"
  agmsg_roster_append_left "$team_dir" "$member_id" alice "2026-01-01T00:00:00Z"

  fake="$TEST_SKILL_DIR/fake-node-unkillable-nofifo"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
while :; do sleep 1; done
EOF
  chmod +x "$fake"
  shim="$(_shim_failing mkfifo)"

  run env PATH="$shim:$PATH" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_ROSTER_SYNC_TIMEOUT_S=2 \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  # Bounded, exactly as with a FIFO: a failure that names itself, no lock, no
  # child. Same three assertions as the FIFO case, deliberately.
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'did not finish within'
  [ ! -d "$team_dir/.config.lock" ]
  refute pgrep -f "$fake"
  # And it must NOT have announced that it was running unbounded — the old
  # sentence is the marker of the path this case exists to remove.
  #
  # `run` AND A STATUS, and neither of the two shapes that come to mind first.
  # `refute` takes a command and a pipe binds tighter, so
  # `refute printf ... | grep` hands `refute` only the `printf` — measured, it
  # failed against output that does not contain the string. And `! cmd` is
  # what `.github/scripts/check-enforced-assertions.sh` refuses: it cannot
  # fail a bats test unless it is the very last line, which makes the
  # assertion's strength depend on where it happens to sit.
  run bash -c 'printf "%s" "$1" | grep -q "without a time bound"' _ "$output"
  [ "$status" -ne 0 ]
}

@test "a failing sleep does not drop the lock beside a live child (#821)" {
  skip_on_windows "POSIX signal delivery is not supported by this test"
  # THE WAIT'S OWN COMMAND CAN BE THE THING THAT FAILS (raised in review).
  #
  # `sleep` is external. Under `set -e` an unguarded one ends this shell where
  # it stands — with the wrapper and node already started, and none of the
  # terminate/KILL/reap reached — and the EXIT trap then releases the lock
  # beside a live writer. That is the contract the timeout path is written to
  # keep, broken by the command it waits with.
  #
  # Driven in POLL mode on purpose: poll is chosen on machines that could not
  # make a FIFO, which is the same population that refuses spawns, so this is
  # where the two failures actually meet. The grace `sleep` on the FIFO path
  # is the same contract and is covered by the same stub — this run reaches
  # both, since a poll-mode timeout still runs the TERM/grace/KILL sequence.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id fake shimdir
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  source "$SCRIPTS/lib/roster-journal.sh"
  agmsg_roster_append_left "$team_dir" "$member_id" alice "2026-01-01T00:00:00Z"

  fake="$TEST_SKILL_DIR/fake-node-unkillable-nosleep"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
while :; do read -r _ 2>/dev/null || :; done
EOF
  chmod +x "$fake"

  # Both stubs in one directory: no FIFO (so poll is chosen) and no sleep (so
  # every wait in the driver has to survive its own tool being broken). The
  # fake node deliberately does NOT call sleep, so the stub cannot stop it.
  shimdir="$TEST_SKILL_DIR/shim-nofifo-nosleep"
  mkdir -p "$shimdir"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$shimdir/mkfifo"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$shimdir/sleep"
  chmod +x "$shimdir/mkfifo" "$shimdir/sleep"

  run env PATH="$shimdir:$PATH" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_ROSTER_SYNC_TIMEOUT_S=2 \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  # A NAMED failure — not the shell's own death from a failed sleep, which
  # would arrive as an unexplained non-zero with no sentence at all.
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'did not finish within'
  # The lock is gone BECAUSE the child was dealt with, not because a trap ran
  # on the way out.
  [ ! -d "$team_dir/.config.lock" ]
  refute pgrep -f "$fake"
}

@test "an unusable pidfile is not read as a child that exited (#821)" {
  skip_on_windows "POSIX signal semantics are not supported by this test"
  # THE OTHER HALF OF "UNKNOWN", and it was the one the code got wrong for
  # longest. With no usable pid there is nothing to ask about -- which is
  # exactly why it must not be read as "the child exited". The wrapper writes
  # that number before it waits, so an empty or garbled pidfile means the
  # wrapper did not get that far, and whether node is running is unknown.
  #
  # The earlier versions cleared the variable and let the predicate return
  # false, which every caller read as "gone" and released on. Mutating
  # `unknown` back to `gone` for this branch left every other case green --
  # measured -- which is what this case is here for.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id fake shimdir made substituted
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  source "$SCRIPTS/lib/roster-journal.sh"
  agmsg_roster_append_left "$team_dir" "$member_id" alice "2026-01-01T00:00:00Z"

  made="$TEST_SKILL_DIR/mktemp-made-garbled"
  substituted="$TEST_SKILL_DIR/pidfile-garbled"
  shimdir="$TEST_SKILL_DIR/shim-garbled"
  mkdir -p "$shimdir"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'out=$(/usr/bin/mktemp "$@") || exit 1'
    printf '%s\n' '[ -e "$out" ] && printf "%s\\n" "$out" >> "$AGMSG_TEST_MKTEMP_MADE"'
    printf '%s\n' 'printf "%s\\n" "$out"'
  } > "$shimdir/mktemp"
  chmod +x "$shimdir/mktemp"

  # Not empty but UNPARSEABLE, so the file still passes `-s` and the refusal
  # has to come from reading the contents rather than from the file's size.
  fake="$TEST_SKILL_DIR/fake-node-garbles-pidfile"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
exec >/dev/null 2>&1
trap '' TERM
( i=0
  while [ "$i" -lt 25 ]; do
    pidfile="$(sed -n '2p' "$AGMSG_TEST_MKTEMP_MADE" 2>/dev/null)"
    if [ -n "$pidfile" ] && [ -s "$pidfile" ]; then
      printf 'not-a-pid\n' > "$pidfile"
      printf 'garbled\n' > "$AGMSG_TEST_SUBSTITUTED"
    fi
    i=$((i + 1))
    sleep 0.1
  done
) &
while :; do sleep 1; done
EOF
  chmod +x "$fake"

  run env PATH="$shimdir:$PATH" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_TEST_MKTEMP_MADE="$made" AGMSG_TEST_SUBSTITUTED="$substituted" \
    AGMSG_ROSTER_SYNC_TIMEOUT_S=4 \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  local driver_status="$status" driver_out="$output"
  # POSITIVE CONTROL: the garbling must have happened, or this is measuring an
  # ordinary timeout that reached the same branch for a different reason.
  [ "$(cat "$substituted" 2>/dev/null || true)" = "garbled" ]

  [ "$driver_status" -eq 18 ]
  printf '%s' "$driver_out" | grep -q 'could not be established'
  [ -d "$team_dir/.config.lock" ]

  local leftover
  leftover="$(pgrep -f "$fake" || true)"
  if [ -n "$leftover" ]; then
    kill $leftover 2>/dev/null || true
    sleep 1
    kill -9 $leftover 2>/dev/null || true
  fi
  rmdir "$team_dir/.config.lock" 2>/dev/null || true
}

@test "a numeric but unusable pid is not read as a child that exited (#821)" {
  skip_on_windows "POSIX signal semantics are not supported by this test"
  # A THIRD WAY INTO "GONE", AND THE OTHER TWO CASES DO NOT REACH IT.
  #
  # `_agmsg_pid_alive_local` refuses a pid above the POSIX ceiling and returns
  # 1 for it -- the same 1 it returns for "no such process". So a value that
  # is all digits but out of range, like 2147483648, passed the crude filter
  # at the call site, was refused by the validator, and that refusal read as
  # `gone` and released the lock. "Could not ask" became "it is dead".
  #
  # `not-a-pid` does not exercise this: it is cleared to empty at the call
  # site and never reaches the validator. This value does.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id fake shimdir made substituted
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  source "$SCRIPTS/lib/roster-journal.sh"
  agmsg_roster_append_left "$team_dir" "$member_id" alice "2026-01-01T00:00:00Z"

  made="$TEST_SKILL_DIR/mktemp-made-oob"
  substituted="$TEST_SKILL_DIR/pidfile-oob"
  shimdir="$TEST_SKILL_DIR/shim-oob"
  mkdir -p "$shimdir"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'out=$(/usr/bin/mktemp "$@") || exit 1'
    printf '%s\n' '[ -e "$out" ] && printf "%s\\n" "$out" >> "$AGMSG_TEST_MKTEMP_MADE"'
    printf '%s\n' 'printf "%s\\n" "$out"'
  } > "$shimdir/mktemp"
  chmod +x "$shimdir/mktemp"

  fake="$TEST_SKILL_DIR/fake-node-oob-pid"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
exec >/dev/null 2>&1
trap '' TERM
( i=0
  while [ "$i" -lt 25 ]; do
    pidfile="$(sed -n '2p' "$AGMSG_TEST_MKTEMP_MADE" 2>/dev/null)"
    if [ -n "$pidfile" ] && [ -s "$pidfile" ]; then
      # INT32_MAX + 1: every character is a digit, and no process can have it.
      printf '2147483648\n' > "$pidfile"
      printf 'oob\n' > "$AGMSG_TEST_SUBSTITUTED"
    fi
    i=$((i + 1))
    sleep 0.1
  done
) &
while :; do sleep 1; done
EOF
  chmod +x "$fake"

  run env PATH="$shimdir:$PATH" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_TEST_MKTEMP_MADE="$made" AGMSG_TEST_SUBSTITUTED="$substituted" \
    AGMSG_ROSTER_SYNC_TIMEOUT_S=4 \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  local driver_status="$status" driver_out="$output"
  [ "$(cat "$substituted" 2>/dev/null || true)" = "oob" ]
  [ "$driver_status" -eq 18 ]
  printf '%s' "$driver_out" | grep -q 'could not be established'
  [ -d "$team_dir/.config.lock" ]

  local leftover
  leftover="$(pgrep -f "$fake" || true)"
  if [ -n "$leftover" ]; then
    kill $leftover 2>/dev/null || true
    sleep 1
    kill -9 $leftover 2>/dev/null || true
  fi
  rmdir "$team_dir/.config.lock" 2>/dev/null || true
}

@test "the production argv matcher: alphabet, quoting, order and boundaries (#821)" {
  # DRIVEN THROUGH THE FUNCTION PRODUCTION CALLS, not a copy of it.
  #
  # The earlier versions of these cases re-implemented the comparison with
  # `bash -c case` and then asserted on the driver with `grep`. That measures
  # a duplicate and a spelling; it cannot notice production diverging from
  # either (raised in review). `agmsg_roster_argv_is_ours` now lives in
  # `scripts/lib/roster-journal.sh` for exactly this reason, and every row
  # below goes through it.
  source "$SCRIPTS/lib/roster-journal.sh"

  local script="/opt/agmsg/scripts/internal/roster-sync.mjs"
  local conf="/opt/agmsg/teams/demo/config.json"
  local other="/opt/agmsg/teams/other/config.json"
  local op="reconcile"

  # --- the run it describes ------------------------------------------------
  agmsg_roster_argv_is_ours "node $script $op $conf 018f 018f 1" "$script" "$op" "$conf"
  # config as the last argument on the line: the padding is what makes this
  # work without a separate end-of-string branch.
  agmsg_roster_argv_is_ours "node $script $op $conf" "$script" "$op" "$conf"

  # --- QUOTED NATIVE ARGV --------------------------------------------------
  # A native Windows command line quotes any argument containing a space. An
  # unquoted needle never matches it, so the real child read as unknown and
  # its lock was kept. This is the shape `compat_get_cmdline` returns from CIM.
  local qs='C:/Users/First Last/.agents/skills/agmsg/scripts/internal/roster-sync.mjs'
  local qc='C:/Users/First Last/.agents/skills/agmsg/teams/demo/config.json'
  agmsg_roster_argv_is_ours "\"C:/Program Files/nodejs/node.exe\" \"$qs\" $op \"$qc\" 018f" \
    "$qs" "$op" "$qc"
  # ...and it is not a rubber stamp once the quotes are gone: another team's
  # config, quoted the same way, is still refused.
  local qo='C:/Users/First Last/.agents/skills/agmsg/teams/other/config.json'
  run agmsg_roster_argv_is_ours "\"node.exe\" \"$qs\" $op \"$qo\" 018f" "$qs" "$op" "$qc"
  [ "$status" -ne 0 ]
  # ...nor is a different operation.
  run agmsg_roster_argv_is_ours "\"node.exe\" \"$qs\" apply \"$qc\" 018f" "$qs" "$op" "$qc"
  [ "$status" -ne 0 ]

  # --- A QUOTED DATA ARGUMENT IS NOT AN INVOCATION -------------------------
  # The first quote fix deleted every `"` from the haystack. It is true that
  # the space between two arguments survives that -- but a quote also carries
  # "the spaces INSIDE me are not argument separators". Strip it, and one
  # quoted argument that merely CONTAINS the triple becomes indistinguishable
  # from a real invocation, and a stranger picked up through pid reuse would
  # be signalled (raised in review).
  run agmsg_roster_argv_is_ours "node other.js --note \"$script $op $conf\" x" \
    "$script" "$op" "$conf"
  [ "$status" -ne 0 ]
  # Same shape with the native paths, since that is where quoting actually
  # arises.
  run agmsg_roster_argv_is_ours "node.exe other.js --note \"$qs $op $qc\" x" \
    "$qs" "$op" "$qc"
  [ "$status" -ne 0 ]
  # And the four legitimate quotings are all accepted -- the two paths are
  # quoted independently, because a path with a space in it is quoted and one
  # without it is not.
  agmsg_roster_argv_is_ours "node \"$script\" $op \"$conf\" x" "$script" "$op" "$conf"
  agmsg_roster_argv_is_ours "node \"$script\" $op $conf x"     "$script" "$op" "$conf"
  agmsg_roster_argv_is_ours "node $script $op \"$conf\" x"     "$script" "$op" "$conf"

  # --- THREE SIGHTINGS ARE NOT A RELATION ----------------------------------
  # A real command line for a DIFFERENT run: `apply` on another team's config,
  # with the word `reconcile` present for an unrelated reason. It satisfies
  # "contains the script", "contains a config" and "contains this operation"
  # all at once.
  local decoy="node $script apply $other --note $op "
  run agmsg_roster_argv_is_ours "$decoy" "$script" "$op" "$conf"
  [ "$status" -ne 0 ]
  run agmsg_roster_argv_is_ours "$decoy" "$script" "$op" "$other"
  [ "$status" -ne 0 ]

  # --- AN ORDERED SUBSTRING IS STILL A SUBSTRING ---------------------------
  run agmsg_roster_argv_is_ours "node $script $op $conf.bak 018f" "$script" "$op" "$conf"
  [ "$status" -ne 0 ]
  run agmsg_roster_argv_is_ours "node /x$script $op $conf 018f" "$script" "$op" "$conf"
  [ "$status" -ne 0 ]

  # --- THE WINDOWS ALPHABET, driven with a cygpath stub --------------------
  # There is no Windows here, so the DIFFERENCE is driven instead. `/c/x`
  # becomes `C:/x` -- the drive letter REPLACES the leading `/c` rather than
  # being prepended to it; prepending leaves the original substring intact and
  # a raw match still fires, which is what the premise control below caught on
  # the first attempt.
  local shimdir="$TEST_SKILL_DIR/shim-cygpath"
  mkdir -p "$shimdir"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '[ "$1" = "-m" ] || exit 1'
    printf '%s\n' 'printf "C:%s\n" "${2#/c}"'
  } > "$shimdir/cygpath"
  chmod +x "$shimdir/cygpath"

  local wsh="/c/Users/agent/.agents/skills/agmsg/scripts/internal/roster-sync.mjs"
  local wconf="/c/Users/agent/.agents/skills/agmsg/teams/demo/config.json"
  local native="node.exe C:${wsh#/c} $op C:${wconf#/c} 018f"

  # PREMISE CONTROL: without cygpath the two alphabets do not match, so the
  # row below is measuring the conversion and not a coincidence.
  run agmsg_roster_argv_is_ours "$native" "$wsh" "$op" "$wconf"
  [ "$status" -ne 0 ]
  # With it, the same input is recognised.
  PATH="$shimdir:$PATH" agmsg_roster_argv_is_ours "$native" "$wsh" "$op" "$wconf"
  # And still refused for another team, converted the same way.
  local wother="/c/Users/agent/.agents/skills/agmsg/teams/other/config.json"
  run env PATH="$shimdir:$PATH" bash -c \
    "source '$SCRIPTS/lib/roster-journal.sh'; agmsg_roster_argv_is_ours '$native' '$wsh' '$op' '$wother'"
  [ "$status" -ne 0 ]

  # --- and the driver calls it ---------------------------------------------
  # The only structural assertion left, and it is about WIRING rather than
  # about the comparison: everything above measures the real function, but
  # nothing above would notice the driver ceasing to call it.
  grep -q 'agmsg_roster_argv_is_ours "\$cmd"' "$SCRIPTS/internal/roster-sync-driver.sh"
}


@test "a TERM already sent is reported, not denied (#821)" {
  skip_on_windows "POSIX signal semantics are not supported by this test"
  # THE STATE CAN CHANGE BETWEEN ONE SIGNAL AND THE NEXT, and the diagnostic
  # used to deny it (raised in review, and it stood for three rounds because I
  # kept answering the other reviewer's items and not this one).
  #
  # The predicate is re-asked before TERM and again before KILL -- which is
  # right, and means a pid that was `ours` at the first can be `unknown` at
  # the second, through recycling or an argv that stopped being readable. The
  # message then said "nothing was signalled on that number", which is FALSE:
  # TERM had already gone out. An operator would go looking for a process
  # nobody had touched.
  #
  # WHAT HAD TO CHANGE IS THE ARGV OF A LIVE PID, not the pidfile. The driver
  # reads the pidfile ONCE, so swapping its contents does nothing -- the first
  # version of this case did that and measured an ordinary timeout (status 14,
  # "confirmed gone"). The real scenario is pid REUSE: the number stays, the
  # process behind it changes, and the argv stops matching.
  #
  # A pid cannot be recycled on demand, so the OBSERVATION is driven instead:
  # `compat_get_cmdline` reads `ps -o args= -p` off Windows, and a `ps` stub
  # answers truthfully until a marker appears and with a decoy afterwards. The
  # fake node traps TERM and drops that marker from inside the handler, so the
  # transition lands exactly between TERM and KILL. It does not exit from the
  # handler, so it survives to be observed.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id fake shimdir made termed
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  source "$SCRIPTS/lib/roster-journal.sh"
  agmsg_roster_append_left "$team_dir" "$member_id" alice "2026-01-01T00:00:00Z"

  made="$TEST_SKILL_DIR/mktemp-made-term"
  termed="$TEST_SKILL_DIR/term-received"
  shimdir="$TEST_SKILL_DIR/shim-term"
  mkdir -p "$shimdir"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'out=$(/usr/bin/mktemp "$@") || exit 1'
    printf '%s\n' '[ -e "$out" ] && printf "%s\\n" "$out" >> "$AGMSG_TEST_MKTEMP_MADE"'
    printf '%s\n' 'printf "%s\\n" "$out"'
  } > "$shimdir/mktemp"
  chmod +x "$shimdir/mktemp"

  # The seam: truthful until the marker exists, a decoy afterwards. Only the
  # `-o args=` form is intercepted, so nothing else that shells out to `ps` --
  # `_agmsg_pid_alive_local`'s own cross-check among them -- is affected.
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'if [ "$1" = "-o" ] && [ "$2" = "args=" ] && [ -e "$AGMSG_TEST_TERMED" ]; then'
    printf '%s\n' '  printf "%s\\n" "some-unrelated-process --after-recycle"'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'exec /bin/ps "$@"'
  } > "$shimdir/ps"
  chmod +x "$shimdir/ps"

  fake="$TEST_SKILL_DIR/fake-node-swaps-on-term"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
exec >/dev/null 2>&1
_on_term() { printf 'termed\n' > "$AGMSG_TEST_TERMED"; }
trap _on_term TERM
while :; do sleep 1; done
EOF
  chmod +x "$fake"

  run env PATH="$shimdir:$PATH" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_TEST_MKTEMP_MADE="$made" AGMSG_TEST_TERMED="$termed" \
    AGMSG_ROSTER_SYNC_TIMEOUT_S=3 \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  local driver_status="$status" driver_out="$output"

  # POSITIVE CONTROL: TERM really reached the child, so the run really did
  # traverse `ours` -> signal -> `unknown`. Without this the case could pass
  # on an ordinary never-identifiable timeout.
  [ "$(cat "$termed" 2>/dev/null || true)" = "termed" ]

  [ "$driver_status" -eq 18 ]
  # It says TERM WENT OUT...
  printf '%s' "$driver_out" | grep -q 'TERM was ATTEMPTED'
  # ...and that KILL was withheld once the number stopped being identifiable.
  printf '%s' "$driver_out" | grep -q 'WITHHELD'
  # ...and it does NOT claim nothing was signalled, which is the false
  # sentence this case exists to remove.
  #
  # `run` and a status, NOT `! cmd`: a non-last `! cmd` cannot fail a bats
  # test anywhere, so writing the negation that way would have shipped an
  # assertion incapable of failing -- exactly the class this PR is about.
  # `.github/scripts/check-enforced-assertions.sh` caught it; the baseline
  # went 638 -> 639 and named the line.
  run bash -c 'printf "%s" "$1" | grep -q "No signal was attempted"' _ "$driver_out"
  [ "$status" -ne 0 ]
  [ -d "$team_dir/.config.lock" ]

  # KILL WAS WITHHELD, observed on the process rather than read from the
  # message: the child is still alive. It ignores nothing -- it has no KILL
  # handler and could not have one -- so its survival is the evidence.
  kill -0 "$(pgrep -f "$fake" | head -1)" 2>/dev/null

  local leftover
  leftover="$(pgrep -f "$fake" || true)"
  if [ -n "$leftover" ]; then
    kill $leftover 2>/dev/null || true
    sleep 1
    kill -9 $leftover 2>/dev/null || true
  fi
  rmdir "$team_dir/.config.lock" 2>/dev/null || true
}

@test "a number once judged not ours is not re-adopted for KILL (#821)" {
  skip_on_windows "POSIX signal semantics are not supported by this test"
  # THE OTHER DIRECTION OF THE TRANSITION, and it is a safety hole rather
  # than a reporting one (raised in review).
  #
  # The predicate is re-asked before TERM and again before KILL, so a number
  # can read `unknown` at the first and `ours` at the second -- recycling, or
  # an instrument that failed once and recovered. The old code then sent KILL
  # to a number it had just refused to send TERM to: escalating against
  # something it had never established a claim on. Escalation is monotone now.
  #
  # Driven by CALL COUNT rather than by a timer, so there is no race: the
  # `ps -o args=` stub answers with a decoy on its first call and truthfully
  # after. The first call is the one before TERM.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id fake shimdir made calls
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  source "$SCRIPTS/lib/roster-journal.sh"
  agmsg_roster_append_left "$team_dir" "$member_id" alice "2026-01-01T00:00:00Z"

  made="$TEST_SKILL_DIR/mktemp-made-readopt"
  calls="$TEST_SKILL_DIR/ps-args-calls"
  shimdir="$TEST_SKILL_DIR/shim-readopt"
  mkdir -p "$shimdir"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'out=$(/usr/bin/mktemp "$@") || exit 1'
    printf '%s\n' '[ -e "$out" ] && printf "%s\\n" "$out" >> "$AGMSG_TEST_MKTEMP_MADE"'
    printf '%s\n' 'printf "%s\\n" "$out"'
  } > "$shimdir/mktemp"
  chmod +x "$shimdir/mktemp"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'if [ "$1" = "-o" ] && [ "$2" = "args=" ]; then'
    printf '%s\n' '  n=$(cat "$AGMSG_TEST_PS_CALLS" 2>/dev/null || echo 0)'
    printf '%s\n' '  n=$((n + 1)); printf %s "$n" > "$AGMSG_TEST_PS_CALLS"'
    printf '%s\n' '  if [ "$n" -eq 1 ]; then'
    printf '%s\n' '    printf "%s\\n" "some-unrelated-process --before-recycle"'
    printf '%s\n' '    exit 0'
    printf '%s\n' '  fi'
    printf '%s\n' 'fi'
    printf '%s\n' 'exec /bin/ps "$@"'
  } > "$shimdir/ps"
  chmod +x "$shimdir/ps"

  fake="$TEST_SKILL_DIR/fake-node-readopt"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
exec >/dev/null 2>&1
trap '' TERM
while :; do sleep 1; done
EOF
  chmod +x "$fake"

  run env PATH="$shimdir:$PATH" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_TEST_MKTEMP_MADE="$made" AGMSG_TEST_PS_CALLS="$calls" \
    AGMSG_ROSTER_SYNC_TIMEOUT_S=3 \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  local driver_status="$status" driver_out="$output"

  # POSITIVE CONTROL ON THE INSTRUMENT: the stub was consulted more than once,
  # so the run really did ask before TERM and again afterwards. With a single
  # call this would be an ordinary never-identifiable timeout and would prove
  # nothing about re-adoption.
  [ "$(cat "$calls" 2>/dev/null || echo 0)" -ge 2 ]

  # THE CHILD IS STILL ALIVE. It ignores TERM, but nothing can ignore KILL --
  # so its survival is the measurement that no KILL was sent to it. This is
  # the assertion the finding is about.
  local alive
  alive="$(pgrep -f "$fake" | head -1 || true)"
  [ -n "$alive" ]
  kill -0 "$alive" 2>/dev/null

  # And the diagnostic does not claim a signal it never attempted.
  printf '%s' "$driver_out" | grep -q 'No signal was attempted'
  [ -d "$team_dir/.config.lock" ]
  # 17: alive and identifiable by the time the decision is taken. Not 14,
  # which would mean the lock came off beside it.
  [ "$driver_status" -eq 17 ]

  local leftover
  leftover="$(pgrep -f "$fake" || true)"
  if [ -n "$leftover" ]; then
    kill $leftover 2>/dev/null || true
    sleep 1
    kill -9 $leftover 2>/dev/null || true
  fi
  rmdir "$team_dir/.config.lock" 2>/dev/null || true
}

@test "a recycled pid is neither signalled nor read as gone (#821)" {
  skip_on_windows "POSIX signal semantics are not supported by this test"
  # "I SENT A SIGNAL" IS NOT "THE PROCESS IS GONE" (raised as BLOCKING).
  #
  # The inner process is a GRANDCHILD, so `wait` cannot speak for it, and
  # every `kill` on that path discards its result. Without asking, the release
  # rested on nothing: a refused signal, and the lock came off beside a live
  # writer.
  #
  # AND A NUMBER IN A FILE IS NOT AN IDENTITY. A pid is recycled the moment
  # its process is reaped, so the number the wrapper wrote can belong to
  # something else by the time the timeout path reads it. The earlier version
  # sent TERM and then KILL to whatever it said.
  #
  # THE STAND-IN IS A PROCESS THIS CASE OWNS, NOT PID 1. An earlier version
  # substituted 1: alive, certainly not ours, and unsignallable -- which made
  # the driver aim TERM and KILL at init on every run of this suite, and
  # proved nothing about restraint either, because a signal to pid 1 leaves no
  # trace an ordinary user can read (raised in review, and right).
  #
  # A `sleep` this case starts answers both. Its argv does not match, so it
  # models a recycled number; and because the case owns it, "no signal was
  # delivered" is DIRECTLY OBSERVABLE -- if TERM had been sent, it would be
  # gone. It is still alive at the end, or this case fails.
  #
  # What the run must produce is the UNKNOWN outcome: nothing signalled, our
  # own child's fate undetermined, and therefore the lock kept. Reading it as
  # "gone" would release on an answer never obtained; reading it as "ours"
  # would mean the driver had adopted a stranger.
  #
  # Nothing in the driver is stubbed. The pidfile is a real file whose path
  # the `mktemp` shim already reports, and the fake node overwrites it the way
  # a pid recycled under the driver's feet would.
  local stranger
  sleep 120 &
  stranger=$!
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local config="$team_dir/config.json"
  local member_id fake shimdir made
  member_id="$(config_field "$config" '$.agents.alice.member_id')"
  source "$SCRIPTS/lib/roster-journal.sh"
  agmsg_roster_append_left "$team_dir" "$member_id" alice "2026-01-01T00:00:00Z"

  made="$TEST_SKILL_DIR/mktemp-made-keep"
  shimdir="$TEST_SKILL_DIR/shim-keep"
  mkdir -p "$shimdir"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'out=$(/usr/bin/mktemp "$@") || exit 1'
    printf '%s\n' '[ -e "$out" ] && printf "%s\\n" "$out" >> "$AGMSG_TEST_MKTEMP_MADE"'
    printf '%s\n' 'printf "%s\\n" "$out"'
  } > "$shimdir/mktemp"
  chmod +x "$shimdir/mktemp"

  # The second real file the driver makes is the pidfile (the first is the
  # sentinel; the FIFO's `mktemp -u` creates nothing and is not logged). The
  # fake waits for the wrapper to have written it, then replaces the number.
  fake="$TEST_SKILL_DIR/fake-node-unkillable-pid"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
# STDOUT IS LET GO HERE, IN THE FIXTURE, AND THAT IS ITS OWN FINDING.
#
# Without this the case hangs -- and not because of the property under test.
# This fake is deliberately one the driver CANNOT kill, so it outlives the
# run; while it holds the caller's stdout, `run` waits for an end-of-file
# that never comes. That is inherent to "a child we may not signal", not
# something the lock gate could fix, and it is reported to the reviewers as
# an observation rather than fixed inside this PR. Released here so the case
# measures the lock and nothing else.
exec >/dev/null 2>&1
trap '' TERM
# SUBSTITUTED REPEATEDLY, NOT ONCE, because once is a race this suite loses.
#
# The wrapper writes the real pid AFTER spawning this process, so a single
# write timed off a `sleep 1` can land first and simply be overwritten. Alone
# the case passed; in the full file, under the load of twenty-odd other cases,
# it did not -- measured, as a status of 14 where 18 was expected. Rewriting
# until just before the driver's budget expires removes the timing question
# from the case entirely.
( i=0
  while [ "$i" -lt 25 ]; do
    pidfile="$(sed -n '2p' "$AGMSG_TEST_MKTEMP_MADE" 2>/dev/null)"
    if [ -n "$pidfile" ] && [ -e "$pidfile" ] && [ -s "$pidfile" ]; then
      printf '%s\n' "$AGMSG_TEST_STRANGER_PID" > "$pidfile"
      # Recorded HERE, not read back from the pidfile afterwards: the driver
      # deletes that file on its way out, so a check made after the run finds
      # an empty string whether or not the substitution happened. Measured --
      # the first version of this control failed for exactly that reason, on a
      # run that had already reached the branch it was checking for.
      printf 'substituted\n' > "$AGMSG_TEST_SUBSTITUTED"
    fi
    i=$((i + 1))
    sleep 0.1
  done
) &
while :; do sleep 1; done
EOF
  chmod +x "$fake"

  local substituted="$TEST_SKILL_DIR/pid-substituted"
  run env PATH="$shimdir:$PATH" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_TEST_MKTEMP_MADE="$made" AGMSG_TEST_SUBSTITUTED="$substituted" \
    AGMSG_TEST_STRANGER_PID="$stranger" AGMSG_ROSTER_SYNC_TIMEOUT_S=4 \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  # POSITIVE CONTROL ON THE SETUP: the substitution must actually have
  # happened, or this case is measuring an ordinary timeout that would have
  # reached the same branch for a different reason.
  [ -s "$made" ]
  [ "$(cat "$substituted" 2>/dev/null || true)" = "substituted" ]

  # KEPT BEFORE ANY OTHER `run`, because `run` overwrites `$output` -- the
  # positive control below is itself a `run`, and with the assertions in the
  # other order it silently began grepping the control's output instead of the
  # driver's. Measured, as an assertion that failed on text that was there.
  local driver_status="$status" driver_out="$output"

  # 18, the UNKNOWN outcome -- not 14 ("stopped and confirmed gone", which
  # would mean the gate did not fire) and not 17 ("ours and still running",
  # which would mean the driver had adopted a stranger.)
  [ "$driver_status" -eq 18 ]
  printf '%s' "$driver_out" | grep -q 'could not be established'
  # THE LOCK IS STILL THERE. This is the assertion the whole finding is about:
  # a release here would be a release beside a writer we could not stop.
  [ -d "$team_dir/.config.lock" ]
  # And the operator is told where it is, since nothing will clean it up.
  printf '%s' "$driver_out" | grep -q "$team_dir/.config.lock"

  # THE OBSERVATION THAT MATTERS, and it is a measurement rather than a
  # reading of the driver's own prose: the process whose number was in the
  # pidfile is STILL ALIVE. TERM would have ended it. This is what "a
  # recycled pid is not signalled" means, checked on the process itself.
  kill -0 "$stranger" 2>/dev/null
  # Positive control on that check: the same assertion must be able to fail.
  # A pid this case never started is not alive, and if `kill -0` could not
  # tell the difference the line above would prove nothing.
  run kill -0 999999
  [ "$status" -ne 0 ]

  kill "$stranger" 2>/dev/null || true
  # The real fake node outlives the driver by design, so it is stopped here by
  # the pid the shell knows. The teardown catches it too; this keeps the
  # window short.
  local leftover
  leftover="$(pgrep -f "$fake" || true)"
  if [ -n "$leftover" ]; then
    kill $leftover 2>/dev/null || true
    sleep 1
    kill -9 $leftover 2>/dev/null || true
  fi
  rmdir "$team_dir/.config.lock" 2>/dev/null || true
}

@test "a partial temp setup leaves nothing behind (#821)" {
  # `mktemp` IS CALLED THREE TIMES, INDEPENDENTLY (raised in review), so
  # "could not build a bound" is not one state: the sentinel can exist while
  # the pidfile failed. Both ways out of that state used to walk past whatever
  # had already been made.
  #
  # It matters because of WHY this path is reached: a temp directory that is
  # full. A feature answering a full filesystem by adding a file to it is the
  # wrong shape.
  #
  # THE STUB FAILS FROM THE THIRD CALL ON, and the number is the whole point.
  #
  # The first call is `mktemp -u`, which only generates a NAME — it creates
  # nothing. So failing from the second call leaves no file either, and the
  # case then passes whether or not anything sweeps up. Measured: with the
  # sweep deleted the case stayed GREEN, which is what sent this comment here.
  # Failing from the third leaves exactly one real file — the sentinel — with
  # the pidfile refused, which is the partial state.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local shimdir counter before after fake
  fake="$TEST_SKILL_DIR/fake-node-partial"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake"
  chmod +x "$fake"

  counter="$TEST_SKILL_DIR/mktemp-calls"
  local made="$TEST_SKILL_DIR/mktemp-made"
  shimdir="$TEST_SKILL_DIR/shim-partial-mktemp"
  mkdir -p "$shimdir"
  # THE SHIM RECORDS WHAT IT ACTUALLY CREATED, and that is not decoration.
  #
  # The first version of this case counted files in `$TMPDIR` before and
  # after. It could not have failed: on macOS `mktemp` with no template
  # IGNORES `TMPDIR` and writes to the per-user directory under /var/folders,
  # so the count was taken of a directory the driver never touched. Measured
  # -- with the sweep deleted the case stayed green, twice.
  #
  # So the paths are logged as they are handed out, and only when the file is
  # really there (`-u` generates a name and creates nothing). The assertion is
  # then about those exact paths, wherever the platform decided to put them.
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'n=$(cat "$AGMSG_TEST_MKTEMP_COUNTER" 2>/dev/null || echo 0)'
    printf '%s\n' 'n=$((n + 1)); printf %s "$n" > "$AGMSG_TEST_MKTEMP_COUNTER"'
    printf '%s\n' '[ "$n" -ge 3 ] && exit 1'
    printf '%s\n' 'out=$(/usr/bin/mktemp "$@") || exit 1'
    printf '%s\n' '[ -e "$out" ] && printf "%s\\n" "$out" >> "$AGMSG_TEST_MKTEMP_MADE"'
    printf '%s\n' 'printf "%s\\n" "$out"'
  } > "$shimdir/mktemp"
  chmod +x "$shimdir/mktemp"

  run env PATH="$shimdir:$PATH" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_TEST_MKTEMP_COUNTER="$counter" AGMSG_TEST_MKTEMP_MADE="$made" \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  # It took the refusal, which is what a partial setup must do.
  [ "$status" -eq 16 ]
  # POSITIVE CONTROL ON THE STUB: three calls means the sentinel's `mktemp`
  # really ran and the pidfile's was refused -- the partial shape, rather than
  # the "nothing was ever made" one the other cases already cover.
  [ "$(cat "$counter")" -ge 3 ]
  # AND A POSITIVE CONTROL ON THE INSTRUMENT: at least one file really
  # existed, so "none of them is left" is not a sentence about an empty list.
  [ -s "$made" ]
  before="$(wc -l < "$made" | tr -d ' ')"
  [ "$before" -ge 1 ]
  after=0
  while IFS= read -r leftover; do
    [ -n "$leftover" ] || continue
    if [ -e "$leftover" ]; then
      after=$((after + 1))
      echo "left behind: $leftover" >&2
    fi
  done < "$made"
  [ "$after" -eq 0 ]
  [ ! -d "$team_dir/.config.lock" ]
}

@test "roster sync refuses, rather than waiting unbounded, when it cannot build a bound (#821)" {
  # `mkfifo` failing has a second way to wait. `mktemp` failing has none: with
  # no sentinel there is nothing to watch, so the choice is between refusing
  # and holding the team lock for an unlimited time. It refuses, and says how
  # to override that on purpose.
  #
  # The child must not be started at all — running it and then complaining is
  # the same unbounded wait with a better message.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local ran="$TEST_SKILL_DIR/refuse-child-ran" fake shim
  fake="$TEST_SKILL_DIR/fake-node-marks"
  printf '%s\n' '#!/bin/sh' 'printf ran > "$AGMSG_TEST_RAN"' 'exit 0' > "$fake"
  chmod +x "$fake"
  shim="$(_shim_failing mktemp)"

  run env PATH="$shim:$PATH" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_TEST_RAN="$ran" \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  [ "$status" -eq 16 ]
  # The reason AND the way out, because a refusal with neither is a wall.
  printf '%s' "$output" | grep -q 'cannot create the temporary files'
  printf '%s' "$output" | grep -q 'AGMSG_ROSTER_SYNC_UNBOUNDED=1'
  # The lock is released by the refusal itself.
  [ ! -d "$team_dir/.config.lock" ]
  # Nothing was run.
  [ ! -e "$ran" ]
}

@test "the unbounded path is still reachable, but only by asking for it (#821)" {
  # FAIL-CLOSED NEEDS A WAY OUT. An operator whose filesystem cannot hold a
  # temp file may still prefer syncing to refusing, and can say so by name.
  # What was removed is the SILENT return to that behaviour, not the behaviour.
  #
  # Driven by a child that exits immediately: this case is about the route
  # being open and announced, and a hanging child here would hang the suite —
  # which is the honest shape of "no bound".
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local ran="$TEST_SKILL_DIR/unbounded-child-ran" fake shim
  fake="$TEST_SKILL_DIR/fake-node-quick"
  printf '%s\n' '#!/bin/sh' 'printf ran > "$AGMSG_TEST_RAN"' 'exit 0' > "$fake"
  chmod +x "$fake"
  shim="$(_shim_failing mktemp)"

  run env PATH="$shim:$PATH" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_TEST_RAN="$ran" AGMSG_ROSTER_SYNC_UNBOUNDED=1 \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null

  [ "$status" -eq 0 ]
  # It ran, and it warned — an unbounded wait taken deliberately still has to
  # be visible in the output of the run that took it.
  [ -e "$ran" ]
  printf '%s' "$output" | grep -q 'NO time bound'
  [ ! -d "$team_dir/.config.lock" ]
}

# Everything under the team directory that a roster operation would move, as
# one string: names, sizes and contents. Used to say "unchanged" about state
# that already exists, which is what a refusal before the lock has to leave.
_roster_state_digest() {
  local dir="$1"
  ( cd "$dir" 2>/dev/null && ls -la . && cat ./*.json ./*.jsonl 2>/dev/null ) | shasum | cut -d' ' -f1
}

@test "roster sync refuses a timeout setting it cannot honour, and does not start the child (#821)" {
  # `read -t` rejects a zero, a negative or a non-numeric budget by failing
  # immediately, and that failure is indistinguishable from "the writer is
  # gone" — so a mistyped setting used to turn the ceiling off and leave the
  # wait unbounded. A bound that a typo removes is not a bound.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo" ran="$TEST_SKILL_DIR/child-ran"
  local fake="$TEST_SKILL_DIR/fake-node-records"
  printf '%s\n' '#!/usr/bin/env bash' ': > "$AGMSG_TEST_RAN"' 'exit 0' > "$fake"
  chmod +x "$fake"

  local before; before="$(_roster_state_digest "$team_dir")"
  local bad
  # The last is all digits and still unusable: `[ "$x" -le 0 ]` on it is beyond
  # the shell's integers and errors, which under `set -e` would end the script
  # with no sentence at all — a silent refusal, which is the thing being fixed.
  for bad in 0 -1 abc 1.5 999999999999999999999999999999; do
    rm -f "$ran"
    run env AGMSG_TEST_RAN="$ran" AGMSG_SYNC_NODE_BIN="$fake" \
      AGMSG_ROSTER_SYNC_TIMEOUT_S="$bad" \
      bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
        018f3f7e-0000-7000-8000-000000000001 \
        018f3f7e-0000-7000-8000-000000000002 1 </dev/null
    # Named, not silent, and not a bare non-zero.
    [ "$status" -ne 0 ]
    printf '%s' "$output" | grep -q 'AGMSG_ROSTER_SYNC_TIMEOUT_S'
    # The child is never started: refusing after the work has begun would
    # leave the state half-written for a setting error.
    [ ! -e "$ran" ]
    # And the team's state is UNCHANGED: the refusal happens before the lock
    # and before `agmsg_roster_ensure`, so a mistyped setting moves nothing.
    # Compared against what was there, because the journal is created by join
    # and "it does not exist" would be asserting the wrong thing.
    [ "$(_roster_state_digest "$team_dir")" = "$before" ]
    # And the lock does not survive the refusal.
    [ ! -d "$team_dir/.config.lock" ]
  done

  # EMPTY IS NOT INVALID — it is unset, and unset takes the default. Asserting
  # a refusal here would pin the opposite of what `${VAR:-120}` does, and the
  # first version of this case did exactly that: it read the default path as a
  # missing guard. Measured, as this test failing against correct code.
  rm -f "$ran"
  run env AGMSG_TEST_RAN="$ran" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_ROSTER_SYNC_TIMEOUT_S="" \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null
  [ "$status" -eq 0 ]
  [ -e "$ran" ]
}

@test "the roster child does not inherit the descriptor used to hand it stdin (#821)" {
  # `<&9` duplicates the caller's stdin onto the child's fd 0 and leaves fd 9
  # open beside it unless the redirection closes it. The child then holds the
  # caller's stream twice — the class that hung a shard twice tonight, arriving
  # through the descriptor added to fix it.
  #
  # Asserted from INSIDE the child, because that is the only place the answer
  # exists: a reader of the source can be told `9<&-` is there, and reading is
  # what let this back in.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo"
  local seen="$TEST_SKILL_DIR/child-fd9" fake="$TEST_SKILL_DIR/fake-node-fd"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'if : <&9 2>/dev/null; then printf open > "$AGMSG_TEST_FD_SEEN"'
    printf '%s\n' 'else printf closed > "$AGMSG_TEST_FD_SEEN"; fi'
    # THE PARENT'S COPY, asked of the parent. $PPID here is the WRAPPER shell
    # that carries node's pid, not the driver -- an earlier version of this
    # comment said it was the driver, and that stopped being true when the
    # wrapper was introduced. The assertion did not need changing: whoever the
    # parent is, it must not be holding the caller's stdin, and this is the
    # instrument that caught the wrapper doing exactly that. Where the table
    # cannot be read -- macOS has no /proc -- this records that it could not
    # look, rather than reporting "closed" from an instrument that cannot see.
    printf '%s\n' 'if [ -d "/proc/$PPID/fd" ]; then'
    printf '%s\n' '  if [ -e "/proc/$PPID/fd/9" ]; then printf parent-open > "$AGMSG_TEST_FD_PARENT"'
    printf '%s\n' '  else printf parent-closed > "$AGMSG_TEST_FD_PARENT"; fi'
    printf '%s\n' 'else printf parent-unreadable > "$AGMSG_TEST_FD_PARENT"; fi'
    printf '%s\n' 'exit 0'
  } > "$fake"
  chmod +x "$fake"

  local parent_seen="$TEST_SKILL_DIR/parent-fd9"
  run env AGMSG_TEST_FD_SEEN="$seen" AGMSG_TEST_FD_PARENT="$parent_seen" \
    AGMSG_SYNC_NODE_BIN="$fake" \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null
  [ "$status" -eq 0 ]
  # The child ran at all — without this the assertions below pass on files
  # that were never written.
  [ -e "$seen" ]
  [ -e "$parent_seen" ]
  [ "$(cat "$seen")" = "closed" ]
  # Where the descriptor table is readable, the parent's copy is gone too.
  # Where it is not, the case says so instead of asserting an answer it did
  # not get: an instrument that cannot look must not report "closed".
  case "$(cat "$parent_seen")" in
    parent-unreadable) : ;;
    *) [ "$(cat "$parent_seen")" = "parent-closed" ] ;;
  esac
  [ ! -d "$team_dir/.config.lock" ]
}

@test "the driver's own copy of that descriptor is closed after the spawn (#821)" {
  # A STRUCTURAL CHECK, and it is here because the behavioural one above cannot
  # run everywhere: reading another live process's descriptors needs /proc, and
  # macOS has none. Reverting the parent's close would then be green on half
  # the matrix — which is how a leak survives.
  #
  # So the order is asserted where it lives, with every anchor required to
  # exist so this cannot pass by finding nothing.
  #
  # THERE ARE THREE COPIES OF fd 9, NOT TWO, AND THAT IS WHY THIS CASE CHANGED.
  # The wrapper that carries node's pid is a shell of its own, and it inherits
  # fd 9 like anything else. Its earlier version closed it nowhere, so the
  # caller's stdin was held for the whole operation by a process that neither
  # the child's close nor the driver's reaches. CI caught it on the /proc half.
  # Each close is anchored separately below, after the spawn it belongs to.
  local sh="$SCRIPTS/internal/roster-sync-driver.sh"
  local node_at wrapper_close_at group_at parent_close_at

  # 1. node is handed the descriptor and drops its saved copy in one redirection.
  node_at="$(grep -n '"\$@" <&9 9<&- 3>&- 4>&- &$' "$sh" | head -1 | cut -d: -f1)"
  # 2. the wrapper closes its own copy — indented inside the brace group.
  wrapper_close_at="$(grep -n '^    exec 9<&-$' "$sh" | head -1 | cut -d: -f1)"
  # 3. the brace group is backgrounded.
  group_at="$(grep -n '^  } 3>&- 4>&- 8> "\$_roster_write_target" &$' "$sh" | head -1 | cut -d: -f1)"
  # 4. the driver closes its copy — at the driver's own indent, which is why
  #    the two `exec 9<&-` anchors cannot be confused for one another.
  parent_close_at="$(grep -n '^  exec 9<&-$' "$sh" | head -1 | cut -d: -f1)"

  [ -n "$node_at" ]
  [ -n "$wrapper_close_at" ]
  [ -n "$group_at" ]
  [ -n "$parent_close_at" ]

  # The wrapper's close is after node has the descriptor, and before the group
  # ends — remove it and this is the assertion that goes red.
  [ "$wrapper_close_at" -gt "$node_at" ]
  [ "$wrapper_close_at" -lt "$group_at" ]
  # The driver's close is after the group is spawned.
  [ "$parent_close_at" -gt "$group_at" ]
}

@test "the timeout setting is validated before the lock is taken (#821)" {
  # WHY THIS IS STRUCTURAL, having tried the other way: moving the validation
  # back after `agmsg_lock_acquire` and `agmsg_roster_ensure` leaves every
  # behavioural assertion green. The refusal still releases the lock, and
  # `agmsg_roster_ensure` is idempotent, so "the team's state is unchanged"
  # cannot tell the two orders apart. Measured — that mutation was run and
  # stayed green.
  #
  # What the order buys is that a setting error never takes the critical
  # section at all, which matters on a machine where taking it is the risky
  # part. So the order is asserted where it lives, with both anchors required
  # to exist so this cannot pass by finding nothing.
  local sh="$SCRIPTS/internal/roster-sync-driver.sh" check_at lock_at
  check_at="$(grep -n 'AGMSG_ROSTER_SYNC_TIMEOUT_S must be a positive' "$sh" | head -1 | cut -d: -f1)"
  lock_at="$(grep -n '^agmsg_lock_acquire "\$team_dir"$' "$sh" | head -1 | cut -d: -f1)"
  [ -n "$check_at" ]
  [ -n "$lock_at" ]
  [ "$check_at" -lt "$lock_at" ]
}

@test "an unusable timeout is refused without waiting for the lock (#821)" {
  # THE ORDER, MEASURED — not read.
  #
  # A held lock is what makes the two orders observably different: validating
  # first refuses at once, validating after `agmsg_lock_acquire` spends the
  # whole lock budget and then reports a lock timeout instead. Without a holder
  # both orders look identical from outside, which is why the first attempt at
  # this control could not discriminate and the property was asserted
  # structurally.
  bash "$SCRIPTS/join.sh" demo alice claude-code /tmp/a
  local team_dir="$TEST_SKILL_DIR/teams/demo" ran="$TEST_SKILL_DIR/child-ran2"
  local fake="$TEST_SKILL_DIR/fake-node-records2"
  printf '%s\n' '#!/usr/bin/env bash' ': > "$AGMSG_TEST_RAN"' 'exit 0' > "$fake"
  chmod +x "$fake"

  # Somebody else holds it. Made by hand rather than by another driver: what
  # matters is that the directory is there, which is exactly what the lock is.
  mkdir -p "$team_dir/.config.lock"

  local began=$SECONDS
  run env AGMSG_TEST_RAN="$ran" AGMSG_SYNC_NODE_BIN="$fake" \
    AGMSG_LOCK_SECONDS=10 AGMSG_ROSTER_SYNC_TIMEOUT_S=0 \
    bash "$SCRIPTS/internal/roster-sync-driver.sh" reconcile demo \
      018f3f7e-0000-7000-8000-000000000001 \
      018f3f7e-0000-7000-8000-000000000002 1 </dev/null
  local took=$((SECONDS - began))

  [ "$status" -ne 0 ]
  # The SETTING is what it complains about, not the lock: reaching the lock at
  # all means the check ran too late.
  printf '%s' "$output" | grep -q 'AGMSG_ROSTER_SYNC_TIMEOUT_S'
  refute grep -q 'timed out acquiring registry lock' <<<"$output"
  # And it did not spend the lock budget getting there.
  [ "$took" -lt 5 ]
  [ ! -e "$ran" ]
  # Someone else's lock is still theirs.
  [ -d "$team_dir/.config.lock" ]
  rmdir "$team_dir/.config.lock"
}
