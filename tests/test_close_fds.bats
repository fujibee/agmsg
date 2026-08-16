#!/usr/bin/env bats

# A long-lived child must not inherit descriptors above stderr.
#
# The failure this guards is silent and expensive: bats hands its result and
# trace descriptors to whatever it runs, a spawned engine or bridge keeps them
# for as long as it lives, and bats then waits for an EOF that cannot arrive.
# Every test reports ok and the CI shard runs to the job cap — observed twice on
# one head, ~25 minutes each, with `Terminate orphan process: (node)` at
# cleanup. Nothing in the test output says what happened.
#
# Asserted on what the child SEES, not on the source of the launcher. A grep for
# `agmsg_close_inherited_fds` would pass on a script that calls it too late, or
# after it has already forked.

LIB="$BATS_TEST_DIRNAME/../scripts/lib/close-fds.sh"

# Descriptors a child can see, one per line. Uses /dev/fd, the same enumeration
# the implementation uses, so a platform without it skips rather than lies.
fds_visible_to_child() {
  ls /dev/fd 2>/dev/null | sort -n
}

setup() {
  [ -d /dev/fd ] || skip "/dev/fd is not available on this platform"
}

# THE HAZARD, shown first: run under bats, a plain child already inherits
# descriptors nobody opened. Measured here rather than asserted from the code —
# on this harness the baseline is `0 1 2 3 4 5 6`, and 5 and 6 are bats's own.
# Those are what a bridge or engine would hold for its whole life.
#
# 3 and 4 belong to the measurement itself (the command-substitution pipe and
# the directory handle), which is why the check below is "nothing above 4"
# rather than a fixed list — the first version of this test asserted 3 and 4
# were absent and failed against a correct implementation.
@test "close-fds: under bats, a child does inherit the harness's descriptors" {
  run bash -c 'ls /dev/fd | sort -n | tr "\n" " "'
  [ "$status" -eq 0 ]
  local leaked=0
  for fd in $output; do
    [ "$fd" -gt 4 ] && leaked=1
  done
  [ "$leaked" -eq 1 ] || skip "this harness leaks nothing; the guard cannot be demonstrated here"
}

@test "close-fds: after the close, the child sees nothing above stderr" {
  run bash -c '
    . "'"$LIB"'"
    exec 13>/dev/null 143>/dev/null
    agmsg_close_inherited_fds
    ls /dev/fd | sort -n | tr "\n" " "
  '
  [ "$status" -eq 0 ]
  # Everything bats handed down, and everything opened above, is gone. Only the
  # measurement's own descriptors remain.
  for fd in $output; do
    [ "$fd" -le 4 ]
  done
}

# The regression that actually bit: closing by name leaves the harness's own
# descriptor open. This fails against `exec 3>&- 4>&-` and passes against the
# range close, which is the whole point of the change.
@test "close-fds: a descriptor the harness chose is closed too" {
  run bash -c '
    . "'"$LIB"'"
    exec 143>/dev/null
    agmsg_close_inherited_fds
    if [ -e /dev/fd/143 ]; then echo LEAKED; else echo CLOSED; fi
  '
  [ "$status" -eq 0 ]
  [[ "$output" =~ "CLOSED" ]]
}

# Every long-lived spawn path must use it. A source check on purpose: it is not
# asserting behaviour, it is asserting that no caller was left behind, and being
# left behind is exactly how the bridge came to hang a shard while the engine
# was already fixed.
#
# _session-start.sh is on this list even though it is SOURCED rather than run.
# It was left off at first, on the reasoning that calling the helper there would
# close the sourcing shell's descriptors — true, and not a reason to leave the
# leak: wrapping only the spawn in a subshell closes the child's copies and
# leaves the parent's alone (review P1). "This one is different" is where
# an exclusion list goes wrong, so the list is now every path, with no
# exceptions to audit.
@test "close-fds: every long-lived spawn path calls it" {
  for f in \
    "$BATS_TEST_DIRNAME/../scripts/remote-sync.sh" \
    "$BATS_TEST_DIRNAME/../scripts/drivers/types/codex/codex-bridge-launcher.sh" \
    "$BATS_TEST_DIRNAME/../scripts/drivers/types/codex/codex-monitor.sh" \
    "$BATS_TEST_DIRNAME/../scripts/drivers/types/codex/_session-start.sh"
  do
    grep -q 'agmsg_close_inherited_fds' "$f" || {
      echo "no fd close in $f"
      false
    }
  done
}
