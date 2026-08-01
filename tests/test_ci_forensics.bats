#!/usr/bin/env bats

# The hang diagnostics are an instrument, so they get tested like one. The
# fixture is real: lsof output captured from a macOS shard that had reported
# every test ok and then sat silent until the job's 25-minute cap.

load test_helper

setup() {
  HOLDERS="$BATS_TEST_DIRNAME/../.github/scripts/pipe-holders.awk"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/hung-shard-lsof.txt"
}

@test "pipe-holders: names the pipe the engine and bats both hold" {
  # This one line is the whole finding. It was already in the 08-01 dump, spread
  # over four per-pid blocks, and was read as "the engine holds nothing of
  # bats's" -- by me. Reading it by eye is the step that failed.
  run awk -f "$HOLDERS" "$FIXTURE"
  [ "$status" -eq 0 ]
  local shared
  shared="$(printf '%s\n' "$output" | grep -F '0x4081ea6d31363d36')"
  [ -n "$shared" ]
  [[ "$shared" == *"node(pid 42776, fd 13)"* ]]
  [[ "$shared" == *"bash(pid 12130, fd 143)"* ]]
  [[ "$shared" == *"bash(pid 12145, fd 143)"* ]]
}

@test "pipe-holders: a pipe whose ends one process holds alone is not reported" {
  # fd 4 and 5 of the engine are its own matched pair. Reporting those would
  # bury the finding in noise, which is the other half of being readable.
  run awk -f "$HOLDERS" "$FIXTURE"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"0x9ed3b7445c820504"* ]]
}

@test "pipe-holders: says so when nothing is shared, rather than printing nothing" {
  # Silence and "no sharing found" look identical, and one of them is a broken
  # instrument.
  run bash -c "printf '%s\n' 'node 1 runner 4 PIPE 0xaaa 16384 ->0xbbb' | awk -f '$HOLDERS'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no pipe is held by more than one"* ]]
}

@test "forensics: one lsof over all candidates, and no per-pid line cap" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"
  # A per-pid loop puts the two ends of a pipe in blocks taken at different
  # moments, which cannot be matched. A cap cut the decisive line in the 08-01
  # hang. Both are how the evidence was there and unusable.
  run grep -F 'lsof -p "$pids"' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'pipe-holders.awk' "$workflow"
  [ "$status" -eq 0 ]
  run grep -E 'lsof -p "\$pid"' "$workflow"
  [ "$status" -ne 0 ]
  run grep -E 'if \(n <= 14\)|NR <= 4' "$workflow"
  [ "$status" -ne 0 ]
}
