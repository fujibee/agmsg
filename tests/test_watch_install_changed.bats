#!/usr/bin/env bats

# A watcher must not keep running after its own installation is replaced (#684).
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
# longer on disk, whatever changed.

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

@test "watch: exits and says so when its own installation is replaced (#684)" {
  local out="$BATS_TEST_TMPDIR/out.txt"
  : > "$out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" sid-684 "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!

  # Positive control FIRST. Without it, a watcher that never started would pass
  # every assertion below by being equally absent -- and "it exited" would be
  # measuring the harness rather than the guard.
  bash "$SCRIPTS/send.sh" team bob alice "before-the-update" >/dev/null
  _wait_for "grep -q 'before-the-update' '$out'" || true
  grep -q 'before-the-update' "$out"
  kill -0 "$pid"

  # The update: something under scripts/ is written after this watcher started.
  # A real install rewrites many files; one is enough to prove the rule.
  touch "$SCRIPTS/config.sh"

  # `|| true` is load-bearing. Under bats a bare command that returns non-zero
  # ends the test THERE, so a `_wait_for` that times out would skip the reap
  # below and leave the watcher holding the test process open -- which is what
  # happened: removing the guard hung this file for ten minutes twice instead of
  # failing in fifteen seconds. The wait not arriving is the interesting case,
  # so it must not be the case that jumps out of the function.
  _wait_for "! kill -0 $pid 2>/dev/null" || true

  # Reap BEFORE asserting, for the same reason: bats stops at the first failed
  # assertion, and a live watcher after that point stalls the runner rather than
  # reporting anything. A mutation has to produce a red test, not a hang.
  local was_alive=0
  kill -0 "$pid" 2>/dev/null && was_alive=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ "$was_alive" -eq 0 ]
  # On STDOUT, not stderr. Every launcher we ship sends this watcher's stderr to
  # /dev/null, which is why the original failure was silent for hours -- so the
  # notice goes to the channel the session is actually reading.
  grep -q 'installation was updated' "$out"
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
  _wait_for "! kill -0 $second 2>/dev/null" || true

  local was_alive=0
  kill -0 "$second" 2>/dev/null && was_alive=1
  kill "$second" 2>/dev/null || true
  wait "$second" 2>/dev/null || true

  [ "$was_alive" -eq 0 ]
  grep -q 'installation was updated' "$out2"
}
