#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-a
  DBPATH="$TEST_SKILL_DIR/db/messages.db"
  BARRIER="$TEST_SKILL_DIR/mark-barrier"
}

teardown() {
  teardown_test_env
}

unread_count() {
  sqlite3 "$DBPATH" "SELECT COUNT(*) FROM messages WHERE team='testteam' AND to_agent='$1' AND read_at IS NULL;" | tr -d '\r'
}

# Wait until the script under test has displayed and is paused before its
# mark UPDATE (barrier .reached appears), with a bounded wait.
await_barrier_reached() {
  for _ in $(seq 1 100); do
    [ -e "$BARRIER.reached" ] && return 0
    sleep 0.05
  done
  return 1
}

# --- inbox.sh -----------------------------------------------------------

@test "inbox: displays unread messages and marks exactly those as read" {
  bash "$SCRIPTS/send.sh" testteam bob alice "first"
  bash "$SCRIPTS/send.sh" testteam bob alice "second"
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 new message(s):"* ]]
  [[ "$output" == *"first"* ]]
  [[ "$output" == *"second"* ]]
  [ "$(unread_count alice)" -eq 0 ]
}

@test "inbox: --quiet is silent when there is nothing unread" {
  run bash "$SCRIPTS/inbox.sh" testteam alice --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inbox: a message arriving between display and mark is NOT marked read unseen" {
  bash "$SCRIPTS/send.sh" testteam bob alice "early"
  # Pause the run between display and mark, land a message inside the window,
  # then release. With the old blanket "WHERE read_at IS NULL" mark, the late
  # message was silently marked read without ever having been displayed.
  AGMSG_TEST_MARK_BARRIER="$BARRIER" bash "$SCRIPTS/inbox.sh" testteam alice > "$TEST_SKILL_DIR/first-run.out" 3>&- &
  bg_pid=$!
  await_barrier_reached
  bash "$SCRIPTS/send.sh" testteam bob alice "late"
  : > "$BARRIER.release"
  wait "$bg_pid"
  run cat "$TEST_SKILL_DIR/first-run.out"
  [[ "$output" == *"early"* ]]
  [[ "$output" != *"late"* ]]
  # The late message must still be unread…
  [ "$(unread_count alice)" -eq 1 ]
  # …and surface on the next check
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"late"* ]]
  [ "$(unread_count alice)" -eq 0 ]
}

# --- check-inbox.sh ------------------------------------------------------

@test "check-inbox: a later team's query failure does not lose earlier teams' messages (#637)" {
  # alice is in two teams; glob order enumerates testteam before zteam.
  bash "$SCRIPTS/join.sh" zteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" zteam bob claude-code /tmp/project-a
  bash "$SCRIPTS/send.sh" testteam bob alice "early"
  bash "$SCRIPTS/send.sh" zteam bob alice "in-zteam"

  # PATH shim: fail (SQLITE_BUSY-style rc=5) exactly the unread SELECT for the
  # second team; everything else passes through to the real sqlite3. testteam's
  # messages are read_at-stamped inside the loop before zteam is queried, so
  # without the loop-failure guard this abort loses them silently.
  REAL_SQLITE3="$(command -v sqlite3)"
  mkdir -p "$TEST_SKILL_DIR/shim"
  cat > "$TEST_SKILL_DIR/shim/sqlite3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *"team='zteam'"*"read_at IS NULL"*) exit 5 ;;
  esac
done
exec "$REAL_SQLITE3" "\$@"
SHIM
  chmod +x "$TEST_SKILL_DIR/shim/sqlite3"

  run env PATH="$TEST_SKILL_DIR/shim:$PATH" \
    bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a < /dev/null
  # testteam's message was already marked read when zteam failed — it MUST
  # still have been emitted, or it is lost forever (never re-offered).
  [[ "$output" == *"early"* ]]
  [[ "$output" != *"in-zteam"* ]]
  # And emitting is not enough on its own: the documented hook contract is
  # that stdout is read as control JSON only on exit 0. (Measured separately,
  # not by this test: Claude Code 2.1.226 via one-shot `claude -p` with a
  # synthetic probe hook processed the JSON on exit 0, 1, 2, and 3 alike --
  # https://github.com/fujibee/agmsg/issues/658. This assertion holds
  # regardless of which behavior a given runtime actually implements, which
  # is the point: it pins the script's OWN exit code, not a claim about what
  # any runtime does with it.) The previous version of this test asserted
  # status 5 here, which reads as "the failure is not swallowed" but leaves
  # the delivering path dependent on a non-zero exit for something it cannot
  # both carry a real payload and safely claim failure with -- see the
  # `check-inbox.sh` comment at this same branch for why exit 0 is correct
  # either way. Asserting the emission while asserting a non-zero status made
  # the defect look like the fix.
  [ "$status" -eq 0 ]
  # The failure is not swallowed either — it moved into the payload, which is
  # the channel that survives. Named team and consequence, so a partial poll
  # cannot be read as a complete one.
  [[ "$output" == *"stopped early"* ]]
  [[ "$output" == *"zteam"* ]]
  [[ "$output" == *"stay unread"* ]]
  # testteam delivered-and-read; zteam untouched, so its message re-surfaces.
  [ "$(unread_count alice)" -eq 0 ]
  [ "$(sqlite3 "$DBPATH" "SELECT COUNT(*) FROM messages WHERE team='zteam' AND to_agent='alice' AND read_at IS NULL;" | tr -d '\r')" -eq 1 ]
}

@test "check-inbox: a message arriving between display and mark is NOT marked read unseen" {
  bash "$SCRIPTS/send.sh" testteam bob alice "early"
  AGMSG_TEST_MARK_BARRIER="$BARRIER" bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a > "$TEST_SKILL_DIR/check-run.out" 2>/dev/null 3>&- &
  bg_pid=$!
  await_barrier_reached
  bash "$SCRIPTS/send.sh" testteam bob alice "late"
  : > "$BARRIER.release"
  wait "$bg_pid" || true
  run cat "$TEST_SKILL_DIR/check-run.out"
  [[ "$output" == *"early"* ]]
  [[ "$output" != *"late"* ]]
  # The late message was not silently marked read by the first run
  [ "$(unread_count alice)" -eq 1 ]
}
