#!/usr/bin/env bats

# The staged-input path, run where it actually matters (#817).
#
# The change these cover exists FOR Windows: the roster driver is handed its
# input as an open file descriptor instead of a pipe, so that nothing is ever in
# a position to SIGKILL a driver that holds the registry lock. Two of the things
# it rests on behave differently on Windows than anywhere else -- Node hands an
# ordinary descriptor to Git Bash as stdin, and Windows cannot unlink a file
# that is still open, so the temp directory is removed on a different route.
#
# `tests/test_remote_sync_engine.bats` runs on ubuntu and macos only. Without
# this file the Windows half of a Windows fix would be argued rather than run.
#
# The name carries `driver-input` because the Windows matrix leg selects by
# `bats --filter`.

@test "driver-input: the staged input arrives whole and leaves nothing behind" {
  # Bounded, so a hang names the test that stopped instead of sitting until the
  # job is cancelled with nothing to read (a 17 minute hang on this leg, #1940's
  # run, ended as "cancelled" with no output at all). --test-timeout fails the
  # stuck test BY NAME; the outer timeout is the backstop for a process that
  # stays alive after that, and is longer so the name is printed first. Where no
  # `timeout` exists the run is as it was.
  local bound=()
  if command -v timeout >/dev/null 2>&1; then bound=(timeout 300); fi
  run "${bound[@]}" node --test --test-timeout=90000 \
    --test-name-pattern 'whole input, from the start|leaves nothing behind' \
    "$BATS_TEST_DIRNAME/remote_sync_engine.test.mjs"
  # The whole captured output on failure, to fd 3, because bats truncates its
  # own "Last output" and the first failure of this leg was unreadable for
  # exactly that reason -- a Windows-only failure with its assertion cut off is
  # a leg that tells you it broke and not what broke.
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&3
  fi
  [ "$status" -eq 0 ]
  # A pattern that selects nothing exits 0 with nothing run, which is precisely
  # the shape of a leg that looks green because it never happened. So the count
  # is asserted, not just the status.
  #
  # On `pass` and `fail`, deliberately not on `tests`. How the runner totals
  # `tests` under a name filter is a version-dependent detail -- whether the
  # unselected ones are excluded or counted as skipped -- and pinning it would
  # make this leg fail on a Node upgrade for a reason that has nothing to do
  # with the code. `pass 2` carries the whole guard on its own: nothing selected
  # means nothing passed.
  echo "$output" | grep -qE '(^|[^0-9])pass 2([^0-9]|$)'
  echo "$output" | grep -qE '(^|[^0-9])fail 0([^0-9]|$)'
}
