#!/usr/bin/env bats

@test "remote CI watches the data plane and its sync contracts" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  run grep -F 'scripts/internal/*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'scripts/drivers/storage/*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'scripts/lib/*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'tests/*sync*.*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'tests/test_remote*.bats' "$workflow"
  [ "$status" -eq 0 ]
}

@test "age-v1 CI exercises every age-gated test with pinned tools" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  run grep -F 'filippo.io/age/cmd/age-keygen@v1.3.1' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'echo "$(go env GOPATH)/bin" >> "$GITHUB_PATH"' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'command -v age >/dev/null' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'command -v age-keygen >/dev/null' "$workflow"
  [ "$status" -eq 0 ]

  # This used to pin a single filtered invocation, which pinned the hole in
  # place: 31 tests gate on age, the shards skip them for want of the binary,
  # and naming one file's worth here left 30 running nowhere -- five of them
  # red. What has to hold is that the set is DISCOVERED, so a new age-gated
  # file cannot land outside every job.
  run grep -F "grep -rl 'skip_if_no_age' tests/*.bats" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'bats --print-output-on-failure $files' "$workflow"
  [ "$status" -eq 0 ]
  # ...and that finding nothing is a failure rather than a quiet pass.
  run grep -F 'no age-gated test files found' "$workflow"
  [ "$status" -eq 0 ]
}
