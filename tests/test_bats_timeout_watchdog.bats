#!/usr/bin/env bats
# BATS_TEST_TIMEOUT starts a watcher that bats ends with `kill` when the test is done.
# A test that leaves a no-op kill() in the test shell keeps the watcher alive for the
# whole timeout, and the file is held that long. CI success cannot show the extra
# wait, so these tests measure it.

load test_helper

@test "a test that stubs kill/sleep/wait does not hold its file for the timeout" {
  local f="$BATS_TEST_TMPDIR/stub.bats"
  cat > "$f" <<EOF
load "$BATS_TEST_DIRNAME/test_helper"
teardown() { teardown_test_env; }
@test "stubs" {
  kill() { :; }
  sleep() { :; }
  wait() { :; }
  true
}
EOF
  local t0=$SECONDS
  run env BATS_TEST_TIMEOUT=40 bats "$f"
  [ "$status" -eq 0 ]
  [ $((SECONDS - t0)) -lt 30 ]
}

@test "every suite with its own teardown that stubs kill/sleep/wait drops the stubs there" {
  local f body bad=""
  for f in "$BATS_TEST_DIRNAME"/*.bats; do
    grep -qE '^[[:space:]]+(kill|sleep|wait)\(\) *\{' "$f" || continue
    grep -qE '^teardown\(\)' "$f" || continue
    body="$(awk '/^teardown\(\)/{p=1} p{print} p&&/^}/{exit}' "$f")"
    case "$body" in
      *teardown_test_env*|*"unset -f"*) ;;
      *) bad="$bad $(basename "$f")" ;;
    esac
  done
  [ -z "$bad" ] || { echo "own teardown keeps kill/sleep/wait stubs:$bad" >&2; return 1; }
}
