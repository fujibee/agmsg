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
  for bad in 0 -1 abc 1.5; do
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
    # THE PARENT'S COPY, asked of the parent. With the FIFO design this child is
    # spawned by the driver shell itself, so $PPID is the driver and its
    # descriptor table answers directly where one is readable. Where it is not
    # -- macOS has no /proc -- this records that it could not look, rather than
    # reporting "closed" from an instrument that cannot see.
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
  # So the order is asserted where it lives: the spawn, then `exec 9<&-`, with
  # both anchors required to exist so this cannot pass by finding nothing.
  local sh="$SCRIPTS/internal/roster-sync-driver.sh" spawn_at close_at
  spawn_at="$(grep -n '<&9 9<&- 3>&- 4>&- 8> "\$_roster_fifo" &' "$sh" | head -1 | cut -d: -f1)"
  close_at="$(grep -n '^  exec 9<&-$' "$sh" | head -1 | cut -d: -f1)"
  [ -n "$spawn_at" ]
  [ -n "$close_at" ]
  [ "$close_at" -gt "$spawn_at" ]
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
