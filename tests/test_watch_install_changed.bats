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
# symptom moves between releases, the cause does not. Any file under scripts/
# being newer than the watcher's own start means it is running code that is no
# longer on disk, whatever changed -- and now that is a restart trigger, not
# just an exit trigger.

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

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

@test "watch: a scripts change with no completed VERSION keeps the original exit, never execs a half-finished install (#684)" {
  local out="$BATS_TEST_TMPDIR/out3.txt"
  : > "$out"
  # Real installs finish within a couple of seconds at most; the incomplete-
  # generation timeout is a production safety net measured in tens of
  # seconds, not something this test should sit through at full length just
  # to observe the fallback. Shortened here only.
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT=2 \
    bash "$SCRIPTS/watch.sh" sid-684c "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!

  bash "$SCRIPTS/send.sh" team bob alice "before-half-update" >/dev/null
  _wait_for "grep -q 'before-half-update' '$out'" || true
  grep -q 'before-half-update' "$out"

  # A change under scripts/ with no matching VERSION write -- what install.sh's
  # own rewrite window looks like mid-copy (#963): some files already
  # rewritten, the completion marker not yet published. Must not be exec'd as
  # a finished generation, and must fall back to the original exit only once
  # the (shortened, above) incomplete-generation timeout elapses -- not
  # immediately, since a real install may still be about to finish.
  touch "$SCRIPTS/config.sh"

  # Same load-bearing `|| true` as the exit-path tests: a timeout here must
  # not skip the reap below and leave a live watcher holding the runner open.
  _wait_for "! kill -0 $pid 2>/dev/null" || true

  local was_alive=0
  kill -0 "$pid" 2>/dev/null && was_alive=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ "$was_alive" -eq 0 ]
  grep -q 'installation was updated' "$out"

  # Second lifecycle, same test (#684 review round 3): a STALE VERSION whose
  # timestamp happens to TIE with this watcher's own start -- a coarse
  # filesystem clock can produce this by coincidence -- must not be read as
  # proof of completion either. A tie proves nothing either way, so only a
  # VERSION strictly newer than the watcher's own start may count; otherwise
  # an old, unrelated VERSION could make a still-mid-copy install look
  # finished the moment its first scripts write lands.
  local out2="$BATS_TEST_TMPDIR/out4.txt"
  : > "$out2"
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT=2 \
    bash "$SCRIPTS/watch.sh" sid-684d "$PROJ" claude-code >"$out2" 2>/dev/null 3>&- 4>&- &
  local pid2=$!

  bash "$SCRIPTS/send.sh" team bob alice "before-tie-update" >/dev/null
  _wait_for "grep -q 'before-tie-update' '$out2'" || true
  grep -q 'before-tie-update' "$out2"

  local stamp
  stamp="$(ls "$TEST_SKILL_DIR"/run/.watch-start.* 2>/dev/null | head -1)"
  [ -n "$stamp" ]
  printf 'stale-unrelated-version\n' > "$TEST_SKILL_DIR/VERSION"
  touch -r "$stamp" "$TEST_SKILL_DIR/VERSION"

  touch "$SCRIPTS/config.sh"

  _wait_for "! kill -0 $pid2 2>/dev/null" || true

  local was_alive2=0
  kill -0 "$pid2" 2>/dev/null && was_alive2=1
  kill "$pid2" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true

  [ "$was_alive2" -eq 0 ]
  grep -q 'installation was updated' "$out2"

  # Third lifecycle (#684 review round 5): an out-of-range override must be
  # rejected back to the fixed 60s production ceiling, not honored as-is.
  # "0" (below the valid 1-60 range) is used rather than a huge value
  # precisely because it is fast to disprove: if it were wrongly honored,
  # the watcher would exit within about one poll cycle of the change, while
  # a wrongly-honored huge value would look identical to correct behavior
  # within any short test window. Staying alive well past that window is
  # what proves the override was rejected -- this test does not wait out
  # the full 60s ceiling itself, only long enough to rule out "0" having
  # taken effect.
  local out3="$BATS_TEST_TMPDIR/out5.txt"
  : > "$out3"
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT=0 \
    bash "$SCRIPTS/watch.sh" sid-684e "$PROJ" claude-code >"$out3" 2>/dev/null 3>&- 4>&- &
  local pid3=$!

  bash "$SCRIPTS/send.sh" team bob alice "before-invalid-override" >/dev/null
  _wait_for "grep -q 'before-invalid-override' '$out3'" || true
  grep -q 'before-invalid-override' "$out3"

  touch "$SCRIPTS/config.sh"
  sleep 5

  local was_alive3=0
  kill -0 "$pid3" 2>/dev/null && was_alive3=1
  kill "$pid3" 2>/dev/null || true
  wait "$pid3" 2>/dev/null || true

  [ "$was_alive3" -eq 1 ]
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
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

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
  kill "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true

  # The successor must still be armed.
  bash "$SCRIPTS/send.sh" team bob alice "successor-control" >/dev/null
  _wait_for "grep -q 'successor-control' '$out2'" || true

  touch "$SCRIPTS/config.sh"
  printf '0.0.0-test\n' > "$TEST_SKILL_DIR/VERSION"
  bash "$SCRIPTS/send.sh" team bob alice "successor-after-update" >/dev/null
  _wait_for "grep -q 'successor-after-update' '$out2'" || true

  # Still armed means it noticed the change and restarted on it (same pid --
  # exec, not a fork) rather than running on with the guard silently off.
  kill -0 "$second"
  grep -q 'successor-after-update' "$out2"

  kill "$second" 2>/dev/null || true
  wait "$second" 2>/dev/null || true
}
