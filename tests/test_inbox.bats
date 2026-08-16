#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-a
  BARRIER="$TEST_SKILL_DIR/mark-barrier"
}

teardown() {
  teardown_test_env
}

# Counts unread via the storage facade (send.sh now writes the event log, not
# the legacy messages table's read_at column — a raw "read_at IS NULL" count
# would silently always read 0 post-flip and never catch a real regression).
unread_count() {
  bash -c '
    source "'"$SCRIPTS"'/lib/storage.sh"
    agmsg_storage_load
    storage_list_unread testteam "$1"
  ' _ "$1" | grep -c .
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
  AGMSG_TEST_MARK_BARRIER="$BARRIER" bash "$SCRIPTS/inbox.sh" testteam alice \
    </dev/null > "$TEST_SKILL_DIR/first-run.out" 3>&- &
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


# Make ONE team's store unreadable without touching any other team's.
#
# Teams share a single store until they are partitioned, so corrupting the file
# a team resolves to by default breaks every team at once -- and then the FIRST
# team fails, which is the harmless case, not the one under test. Switching this
# team to its own partition first is what makes the failure land where the
# defect needs it: after an earlier team has already been marked read.
_break_only_this_teams_store() {
  local team="$1" cfg="$TEST_SKILL_DIR/teams/$1/config.json" updated db
  updated="$(sqlite_mem "SELECT json_set(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.drivers.partition', 'per-team');")"
  printf '%s' "$updated" > "$cfg"
  db="$(cd "$TEST_SKILL_DIR" && bash -c '. scripts/lib/storage.sh; agmsg_storage_load; agmsg_db_path '"$team" 2>/dev/null)"
  [ -n "$db" ] || return 1
  mkdir -p "$(dirname "$db")"
  printf 'not a database' > "$db"
}

# --- check-inbox.sh ------------------------------------------------------

# What the hook runtimes actually do with a Stop-hook run, applied to a real
# invocation of check-inbox.sh.
#
# The contract is theirs, not ours: as DOCUMENTED, stdout is read as control
# JSON only when the process exits 0, and a non-zero exit is logged as a hook
# failure with the output discarded. Measured on Claude Code 2.1.226 it was
# processed on exit 0, 1, 2 and 3 alike (#658), so the two disagree — and this
# helper models the documented rule deliberately, because a helper that assumed
# the laxer observed behaviour would stop catching the defect on any runtime
# that follows the document. Asserting on the shell's stdout alone cannot see
# either: the first attempt at this fix emitted the messages and then exited
# non-zero, so it was inert on the only path that was broken while its tests
# passed.
#
# The parse is part of the contract too. Returning raw stdout would stay green
# for malformed JSON, for a payload under some other key, or for text outside
# `reason` — none of which an operator would ever see. So this parses, requires
# `decision` to be `block`, and returns ONLY `reason`: exactly the bytes the
# runtime puts in front of a person.
#
# Prints that text, or nothing at all.
delivered_to_operator() {
  local out status
  out="$(bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a </dev/null 2>/dev/null)" && status=0 || status=$?
  [ "$status" -eq 0 ] || return 0                 # the runtime's rule
  [ -n "$out" ] || return 0
  # Valid JSON, decision=block, and then the reason — each a separate gate so a
  # payload that fails any one of them delivers nothing.
  local esc parsed
  esc="$(printf '%s' "$out" | sed "s/'/''/g")"
  parsed="$(sqlite_mem "SELECT CASE
      WHEN json_valid('$esc') = 0 THEN ''
      WHEN json_extract('$esc', '\$.decision') IS NOT 'block' THEN ''
      ELSE COALESCE(json_extract('$esc', '\$.reason'), '') END;")"
  printf '%s' "$parsed"
}

@test "check-inbox: a broken team stops the poll without losing either side (#637)" {
  # Three teams, so the payload's own claim can be checked against reality:
  #   aateam  succeeds and is marked read   -> must be DELIVERED
  #   mmteam  store unreadable              -> stops the loop
  #   zzteam  holds an unread message       -> must stay unread, undelivered
  #
  # Two teams could not test this. The text says "teams after it were not
  # checked; their messages stay unread" — with nothing after the failure that
  # sentence was unverified, and a version that silently consumed the rest
  # would have passed.
  bash "$SCRIPTS/join.sh" aateam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/join.sh" aateam bob claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/join.sh" mmteam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/join.sh" zzteam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/join.sh" zzteam bob claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/send.sh" aateam bob alice "before the break" >/dev/null
  bash "$SCRIPTS/send.sh" zzteam bob alice "after the break" >/dev/null
  _break_only_this_teams_store mmteam

  run delivered_to_operator

  # The earlier team's message reached a person.
  [[ "$output" == *"before the break"* ]]
  # The later team's did not.
  [[ "$output" != *"after the break"* ]]
  # And the payload says why, naming the team it stopped on.
  [[ "$output" == *"stopped early"* ]]
  [[ "$output" == *"mmteam"* ]]
  [[ "$output" == *"stay unread"* ]]

  # The claim matches the store: the later team's message is still unread, so
  # the next poll will offer it.
  local left
  left="$(bash -c '
    source "'"$SCRIPTS"'/lib/storage.sh"
    agmsg_storage_load
    storage_list_unread zzteam alice
  ' | grep -c .)"
  [ "$left" -eq 1 ]
}

@test "check-inbox: a failure with nothing accumulated does not report 'no new messages' (#637)" {
  # The other half. With nothing to deliver there is no payload to protect, so
  # the status is free to carry the failure — and it must, because claiming
  # "no new messages" states something this run never established.
  bash "$SCRIPTS/join.sh" zzlastteam alice claude-code /tmp/project-a >/dev/null
  _break_only_this_teams_store zzlastteam

  run bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" != *"no new messages"* ]]
}

@test "bash: a condition context suppresses a nested set -e, even after a later sentinel (#637)" {
  # The property the boundary depends on, pinned on its own so nobody has to
  # rediscover it from a broken poll.
  #
  # A subshell that sets its own `set -e` still does not abort when the whole
  # substitution is the left side of `||` — and the trap is not that the status
  # is lost, it is that a LATER command supplies a different one. Checking only
  # "does a failure come out" misses it whenever a sentinel follows the failure,
  # which is exactly the shape that made a backend error read as "no unread".
  run bash -c '
    set -euo pipefail
    out=$( set -euo pipefail; false; [ -n "" ] || exit 98; echo unreachable ) || rc=$?
    printf "conditional=%s\n" "${rc:-0}"
  '
  [ "$status" -eq 0 ]
  # 98, not 1: the false did not stop it, the sentinel two commands later did.
  [[ "$output" == *"conditional=98"* ]]

  run bash -c '
    set -euo pipefail
    set +e
    out=$( set -euo pipefail; false; [ -n "" ] || exit 98; echo unreachable )
    rc=$?
    set -e
    printf "plain=%s\n" "$rc"
  '
  [ "$status" -eq 0 ]
  # 1: the failure is what came out, because nothing ran after it.
  [[ "$output" == *"plain=1"* ]]
}

@test "check-inbox: a message arriving between display and mark is NOT marked read unseen" {
  bash "$SCRIPTS/send.sh" testteam bob alice "early"
  AGMSG_TEST_MARK_BARRIER="$BARRIER" bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a \
    </dev/null > "$TEST_SKILL_DIR/check-run.out" 2>/dev/null 3>&- &
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
