#!/usr/bin/env bats

# A watcher must never keep running CODE FROM BEFORE its own installation was
# replaced (#684) -- it must restart onto the new code instead, so delivery
# never has to be re-armed by hand after every install (#684 follow-up).
#
# An update rewrites the scripts in place -- same inode, confirmed with lsof --
# so a resident watcher goes on executing the code it started with while
# everything it talks to has moved on. Measured on real installs, one cause
# produced two different symptoms depending on which versions were involved:
#
#   1.1.13 -> 1.2.0-rc.1   watcher alive, delivered NOTHING, message left unread
#   1.1.13 -> 1.2.0-rc.3   watcher alive, delivery still worked, read state stuck
#   1.2.0-rc.1 -> rc.3     nothing observable
#
# That spread is why the guard here is not tied to a table or a schema: the
# symptom moves between releases, the cause does not. An install that finished
# after the watcher's own start (VERSION, its last write, newer than the start)
# means it is running code that is no longer on disk, whatever changed -- and
# that is a restart trigger, not just an exit trigger. A file changed under
# scripts/ without an install finishing is not (#1863).

load test_helper

setup() {
  setup_test_env
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) export AGMSG_AGENT_PID="" ;; esac
  export PROJ="/tmp/agmsg-watch-install-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

# Wait until <condition> holds, up to ~15s. Returns non-zero if it never did, so
# a failure names the thing that did not happen rather than surfacing later as a
# missing grep. Same reasoning as the helpers in test_watch.bats.
_wait_for() {
  local i=0
  while [ "$i" -lt 150 ]; do
    if eval "$1"; then return 0; fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

# When the expected line never arrived, say what the watcher looked like, so a
# red CI run shows whether it died, was still starting, or was alive and silent.
# Every step is best-effort and read-only: history.sh lists messages without
# marking anything read (inbox.sh would consume the message under test), and a
# missing file or directory must not abort before the caller's own assertion.
_explain_if_missing() {   # <out-file> <pid> <needle>
  grep -q "$3" "$1" 2>/dev/null && return 0
  {
    echo "--- watcher output ($1) ---"
    cat "$1" 2>&1 || true
    if kill -0 "$2" 2>/dev/null; then echo "--- pid $2 alive ---"; else echo "--- pid $2 gone ---"; fi
    echo "--- run dir ---"
    ls -la "$TEST_SKILL_DIR/run" 2>&1 || true
    echo "--- recent messages (read-only) ---"
    bash "$SCRIPTS/history.sh" team alice 5 2>&1 | head -10 || true
  } >&3 2>/dev/null || true
  return 0
}

@test "watch: restarts on the new code and keeps delivering, one process, no duplicate, when its own installation is replaced (#684)" {
  local out="$BATS_TEST_TMPDIR/out.txt"
  : > "$out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" sid-684 "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!

  # Positive control FIRST. Without it, a watcher that never started would pass
  # every assertion below by being equally absent -- and "kept delivering" would
  # be measuring the harness rather than the guard.
  bash "$SCRIPTS/send.sh" team bob alice "before-the-update" >/dev/null
  _wait_for "grep -q 'before-the-update' '$out'" || true
  grep -q 'before-the-update' "$out"
  kill -0 "$pid"

  # The update: replace the installed watch.sh with a modified copy, the same
  # way a real install rewrites it. A marker line unique to the new copy is
  # what lets this test tell "the restarted process is running the new code"
  # from "the old process merely survived" -- the two would look identical if
  # this only checked that delivery continued. VERSION is install.sh's own
  # last write that touches anything under scripts/ (see _install_complete);
  # writing it here is what tells the watcher this generation is finished,
  # not still mid-copy.
  awk 'NR==1 { print; print "echo watch-test-new-code-marker"; next } { print }' \
    "$SCRIPTS/watch.sh" > "$SCRIPTS/watch.sh.new"
  chmod +x "$SCRIPTS/watch.sh.new"
  mv "$SCRIPTS/watch.sh.new" "$SCRIPTS/watch.sh"

  # A real install's own scripts/ writes and its VERSION write are separate
  # steps too, so a poll landing between them is not a rare accident -- it is
  # the normal case. This sleep, longer than AGMSG_WATCH_INTERVAL above,
  # guarantees at least one poll lands in that gap here, so a regression in
  # _handle_install_changed's wait-for-ready behavior fails this test every
  # time rather than one time in several (#684 review round 4 -- reproduced
  # under bash 3.2 at roughly a coin flip before this fix).
  sleep 2
  printf '0.0.0-test\n' > "$TEST_SKILL_DIR/VERSION"

  bash "$SCRIPTS/send.sh" team bob alice "after-the-update" >/dev/null
  _wait_for "grep -q 'after-the-update' '$out'" || true

  # Still the SAME pid: exec replaces the process image without forking, so
  # there is never a moment with two watchers polling this subscription.
  kill -0 "$pid"
  grep -q 'watch-test-new-code-marker' "$out"
  grep -qF 'after-the-update' "$out"
  run grep -c 'after-the-update' "$out"
  [ "$output" = "1" ]

  agmsg_stop_pid "$pid"
}

# #1863: only a finished install (VERSION written after the watcher started) is
# an update. A file added or edited under scripts/ by hand, mid-copy or not,
# never stops the watcher or re-execs it.
@test "watch: a change under scripts/ with no VERSION write keeps the watcher running (#1863)" {
  local out="$BATS_TEST_TMPDIR/out3.txt"
  : > "$out"
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT=2 \
    bash "$SCRIPTS/watch.sh" sid-1863a "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!

  bash "$SCRIPTS/send.sh" team bob alice "before-stray" >/dev/null
  _wait_for "grep -q 'before-stray' '$out'" || true
  grep -q 'before-stray' "$out"

  touch "$SCRIPTS/config.sh"
  : > "$SCRIPTS/stray-data-file"
  # A stale VERSION that only ties with the watcher's start is not a finish either.
  local stamp
  stamp="$(ls "$TEST_SKILL_DIR"/run/.watch-start.* 2>/dev/null | head -1)"
  [ -n "$stamp" ]
  printf 'stale-unrelated-version\n' > "$TEST_SKILL_DIR/VERSION"
  touch -r "$stamp" "$TEST_SKILL_DIR/VERSION"
  sleep 5

  bash "$SCRIPTS/send.sh" team bob alice "after-stray" >/dev/null
  _wait_for "grep -q 'after-stray' '$out'" || true
  local was_alive=0
  kill -0 "$pid" 2>/dev/null && was_alive=1
  agmsg_stop_pid "$pid"
  rm -f "$SCRIPTS/stray-data-file"

  [ "$was_alive" -eq 1 ]
  grep -q 'after-stray' "$out"
  refute grep -q 'installation was updated' "$out"
}

@test "watch: a finished install whose watch.sh is not runnable keeps the watcher delivering, says so once, and restarts when it is repaired (#684)" {
  local out="$BATS_TEST_TMPDIR/out4.txt"
  : > "$out"
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT=2 \
    bash "$SCRIPTS/watch.sh" sid-684c "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!

  bash "$SCRIPTS/send.sh" team bob alice "before-broken-update" >/dev/null
  _wait_for "grep -q 'before-broken-update' '$out'" || true
  _explain_if_missing "$out" "$pid" 'before-broken-update'
  grep -q 'before-broken-update' "$out"

  # VERSION must be strictly newer than the watcher's start stamp (see
  # _install_complete). bash 3.2 compares whole seconds, so a VERSION written in
  # the same second as the stamp is a tie and reads as "not finished": a fast
  # runner delivers the first message and gets here inside that second. A real
  # install takes longer than that; the test has to wait it out.
  sleep 2
  chmod -x "$SCRIPTS/watch.sh"
  printf 'new-version\n' > "$TEST_SKILL_DIR/VERSION"

  # Past the grace the watcher says so, once, and does NOT stop.
  _wait_for "grep -q 'still executing the code from before the update' '$out'" || true
  _explain_if_missing "$out" "$pid" 'still executing the code from before the update'
  grep -q 'still executing the code from before the update' "$out"
  # The degraded record is written (just after the line) and names the way out.
  _wait_for "grep -q '\"state\":\"degraded\"' '$TEST_SKILL_DIR/run/down/watch-install.$pid.json'" || true
  grep -q '"state":"degraded"' "$TEST_SKILL_DIR/run/down/watch-install.$pid.json"
  sleep 2
  kill -0 "$pid"
  run grep -c 'still executing the code from before the update' "$out"
  [ "$output" = "1" ]

  # It still delivers with the code it has.
  bash "$SCRIPTS/send.sh" team bob alice "while-broken" >/dev/null
  _wait_for "grep -q 'while-broken' '$out'" || true
  grep -q 'while-broken' "$out"

  # Repaired: it restarts onto the new code by itself (same pid, exec), no manual re-arm.
  awk 'NR==1 { print; print "echo watch-test-repaired-marker"; next } { print }' \
    "$SCRIPTS/watch.sh" > "$SCRIPTS/watch.sh.new"
  chmod +x "$SCRIPTS/watch.sh.new"
  mv "$SCRIPTS/watch.sh.new" "$SCRIPTS/watch.sh"
  _wait_for "grep -q 'watch-test-repaired-marker' '$out'" || true
  # The record goes away once the watcher has restarted onto the repaired install.
  _wait_for "[ ! -e '$TEST_SKILL_DIR/run/down/watch-install.$pid.json' ]" || true
  [ ! -e "$TEST_SKILL_DIR/run/down/watch-install.$pid.json" ]
  local was_alive=0
  kill -0 "$pid" 2>/dev/null && was_alive=1
  grep -q 'watch-test-repaired-marker' "$out"
  agmsg_stop_pid "$pid"
  [ "$was_alive" -eq 1 ]
}

@test "watch: an installation that never stops looking changed does not end the watcher after the restart cap (#684)" {
  local out="$BATS_TEST_TMPDIR/out5.txt"
  : > "$out"
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_INSTALL_RESTART_MIN_AGE=3 \
    bash "$SCRIPTS/watch.sh" sid-684d "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!

  bash "$SCRIPTS/send.sh" team bob alice "before-churn" >/dev/null
  _wait_for "grep -q 'before-churn' '$out'" || true
  grep -q 'before-churn' "$out"

  # A VERSION stamped in the future reads as newer than every watcher start, so
  # each restarted image sees "changed" again -- the loop the cap exists for.
  printf 'future-version\n' > "$TEST_SKILL_DIR/VERSION"
  touch -t 203801010000 "$TEST_SKILL_DIR/VERSION"

  _wait_for "grep -q 'kept changing across 5 restart' '$out'" || true
  _explain_if_missing "$out" "$pid" 'kept changing across 5 restart'
  grep -q 'kept changing across 5 restart' "$out"
  _wait_for "grep -q '\"state\":\"degraded\"' '$TEST_SKILL_DIR/run/down/watch-install.$pid.json'" || true
  grep -q '"state":"degraded"' "$TEST_SKILL_DIR/run/down/watch-install.$pid.json"
  sleep 2
  # Still the same process, still serving the subscription, and it said so once.
  kill -0 "$pid"
  run grep -c 'kept changing across 5 restart' "$out"
  [ "$output" = "1" ]
  bash "$SCRIPTS/send.sh" team bob alice "after-churn" >/dev/null
  _wait_for "grep -q 'after-churn' '$out'" || true
  grep -q 'after-churn' "$out"

  # Past the cap a restart is still tried once the image is old enough (3 s here),
  # and the record that says the install is not settling survives that hand-over.
  local rec="$TEST_SKILL_DIR/run/down/watch-install.$pid.json" since_before since_after n
  since_before="$(sed -n 's/.*"since":"\([^"]*\)".*/\1/p' "$rec")"
  [ -n "$since_before" ]
  _wait_for "[ \"\$(grep -c 'restarting on the new code' '$TEST_SKILL_DIR/run/watch.sid-684d.log')\" -ge 7 ]" || true
  n="$(grep -c 'restarting on the new code' "$TEST_SKILL_DIR/run/watch.sid-684d.log")"
  [ "$n" -ge 7 ]
  kill -0 "$pid"
  grep -q '"state":"degraded"' "$rec"
  since_after="$(sed -n 's/.*"since":"\([^"]*\)".*/\1/p' "$rec")"
  [ "$since_after" = "$since_before" ]
  run grep -c 'kept changing across 5 restart' "$out"
  [ "$output" = "1" ]

  # The install settles (VERSION no longer newer than the watcher): the run of
  # restarts ends and the record goes.
  # The record cannot be removed at first (its directory is read-only): the removal
  # stays pending, the watcher keeps running, and it is retried until it works.
  chmod 555 "$TEST_SKILL_DIR/run/down"
  touch -t 202001010000 "$TEST_SKILL_DIR/VERSION"
  sleep 3
  kill -0 "$pid"
  [ -e "$rec" ]
  chmod 755 "$TEST_SKILL_DIR/run/down"
  _wait_for "[ ! -e '$rec' ]" || true
  [ ! -e "$rec" ]
  local was_alive=0
  kill -0 "$pid" 2>/dev/null && was_alive=1
  agmsg_stop_pid "$pid"
  [ "$was_alive" -eq 1 ]
}

@test "watch: a degraded record that could not be written is tried again, and the report line still appears once (#684)" {
  local out="$BATS_TEST_TMPDIR/out6.txt" down="$TEST_SKILL_DIR/run/down"
  : > "$out"
  mkdir -p "$down"
  chmod 555 "$down"
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT=2 \
    bash "$SCRIPTS/watch.sh" sid-684e "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  bash "$SCRIPTS/send.sh" team bob alice "before-unwritable" >/dev/null
  _wait_for "grep -q 'before-unwritable' '$out'" || true
  sleep 2
  chmod -x "$SCRIPTS/watch.sh"
  printf 'new-version\n' > "$TEST_SKILL_DIR/VERSION"
  _wait_for "grep -q 'still executing the code from before the update' '$out'" || true
  grep -q 'still executing the code from before the update' "$out"
  sleep 2
  # The record directory is not writable, so nothing is there yet ...
  [ -z "$(ls "$down" 2>/dev/null)" ]
  # ... and once it is, the next pass writes it, without a second report line.
  chmod 755 "$down"
  _wait_for "grep -q '\"state\":\"degraded\"' '$down/watch-install.$pid.json'" || true
  local ok=0
  grep -q '"state":"degraded"' "$down/watch-install.$pid.json" 2>/dev/null && ok=1
  run grep -c 'still executing the code from before the update' "$out"
  local reports="$output"
  chmod +x "$SCRIPTS/watch.sh"
  agmsg_stop_pid "$pid"
  [ "$ok" -eq 1 ]
  [ "$reports" = "1" ]
}

@test "watch: keeps running when nothing in the installation changes (#684)" {
  # The guard watches a directory the watcher itself writes into if scoped
  # wrongly: pidfiles and readiness sentinels live under run/. Scoped to
  # scripts/ they cannot trip it -- and this is what says so. Without this, a
  # guard that fired on its own pidfile would still pass the test above.
  local out="$BATS_TEST_TMPDIR/out2.txt"
  : > "$out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" sid-684b "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!

  bash "$SCRIPTS/send.sh" team bob alice "first" >/dev/null
  _wait_for "grep -q 'first' '$out'" || true

  bash "$SCRIPTS/send.sh" team bob alice "second" >/dev/null
  _wait_for "grep -q 'second' '$out'" || true
  grep -q 'second' "$out"

  # Same ordering as above: reap first, assert on what was captured.
  local was_alive=0
  kill -0 "$pid" 2>/dev/null && was_alive=1
  agmsg_stop_pid "$pid"

  [ "$was_alive" -eq 1 ]
  run grep -c 'installation was updated' "$out"
  [ "$output" = "0" ]
}

@test "watch: a superseded watcher's cleanup does not disarm its successor (#684)" {
  # Monitor re-invoked for the same session id leaves the old watcher running
  # until the successor kills it (#66), and both run cleanup. When the stamp was
  # named for the session alone it was one file shared between them, so the
  # loser's EXIT trap deleted the winner's -- and `_install_changed` treats a
  # missing stamp as "nothing changed", so the successor kept running with the
  # guard silently off. Found in review, and invisible to the two tests above
  # because each of them only ever has one watcher.
  local out1="$BATS_TEST_TMPDIR/first.txt" out2="$BATS_TEST_TMPDIR/second.txt"
  : > "$out1"; : > "$out2"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" shared-sid "$PROJ" claude-code >"$out1" 2>/dev/null 3>&- 4>&- &
  local first=$!
  _wait_for "[ -s '$TEST_SKILL_DIR/run/watch.shared-sid.pid' ]" || true

  # Same session id: this one takes the slot and stops the first (#66).
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" shared-sid "$PROJ" claude-code >"$out2" 2>/dev/null 3>&- 4>&- &
  local second=$!
  _wait_for "! kill -0 $first 2>/dev/null" || true
  agmsg_stop_pid "$first"

  # The successor must still be armed.
  bash "$SCRIPTS/send.sh" team bob alice "successor-control" >/dev/null
  _wait_for "grep -q 'successor-control' '$out2'" || true

  touch "$SCRIPTS/config.sh"
  sleep 2   # VERSION must be strictly newer than the stamp; see test 3
  printf '0.0.0-test\n' > "$TEST_SKILL_DIR/VERSION"
  bash "$SCRIPTS/send.sh" team bob alice "successor-after-update" >/dev/null
  _wait_for "grep -q 'successor-after-update' '$out2'" || true

  # Still armed means it noticed the change and restarted on it (same pid --
  # exec, not a fork) rather than running on with the guard silently off.
  kill -0 "$second"
  grep -q 'successor-after-update' "$out2"

  agmsg_stop_pid "$second"
}

@test "watch test diagnostic: lists what the watcher saw without reading the unread message, and survives a missing file" {
  bash "$SCRIPTS/send.sh" team bob alice "still-unread" >/dev/null
  _explain_if_missing "$BATS_TEST_TMPDIR/does-not-exist.txt" 999999 'never-there'
  run bash "$SCRIPTS/inbox.sh" team alice
  [ "$status" -eq 0 ]
  case "$output" in *still-unread*) ;; *) false ;; esac
}
