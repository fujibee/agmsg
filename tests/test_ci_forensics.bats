#!/usr/bin/env bats

# The hang diagnostics are an instrument, so they are tested like one, against
# lsof output CAPTURED on each platform rather than written by hand. The columns
# and fields do not mean the same thing on the two runners, and a parser that
# guesses wrong does not fail quietly -- it folds unrelated pipes together and
# reports the whole runner as shared, which would mislead the next diagnosis
# exactly as the last one was misled.

load test_helper

setup() {
  HOLDERS="$BATS_TEST_DIRNAME/../.github/scripts/pipe-holders.awk"
  MACOS="$BATS_TEST_DIRNAME/fixtures/lsof-F-macos-shared-pipe.txt"
  LINUX="$BATS_TEST_DIRNAME/fixtures/lsof-F-linux-shared-pipe.txt"
}

@test "pipe-holders: macOS — an inherited pipe end is reported once, with both processes" {
  # Captured from a shell holding a pipe on two descriptors (fd 8 is a dup of
  # fd 9) with a child that inherited both. Two processes, four rows.
  run awk -f "$HOLDERS" "$MACOS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0xba18ae3ec653d712"* ]]
  [[ "$output" == *"by 2 processes"* ]]
  [[ "$output" == *"bash(pid 72161, fd 9)"* ]]
  [[ "$output" == *"sleep(pid 72163, fd 9)"* ]]
}

@test "pipe-holders: macOS — one process holding a pipe on two descriptors is not sharing" {
  # The same capture with the child's records removed: fd 8 and fd 9 of one
  # process, one pipe. Counting rows instead of processes calls that shared, and
  # a false positive here sends the next reader after the wrong process.
  run bash -c "awk '/^p72161\$/{k=1} /^p72163\$/{k=0} k' '$MACOS' | awk -f '$HOLDERS'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no pipe is held by more than one"* ]]
}

@test "pipe-holders: Linux — pipes are told apart by inode, not folded together" {
  # Captured in a container. Every Linux pipe row carries the same device
  # (D0xe) and the literal name "pipe", so keying on either would collapse all
  # of them into a single entry and report every process as sharing it.
  run awk -f "$HOLDERS" "$LINUX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"inode:631802"* ]]
  [[ "$output" == *"inode:647171"* ]]
  # Distinct pipes stay distinct.
  local groups
  groups="$(printf '%s\n' "$output" | grep -c '^SHARED ')"
  [ "$groups" -ge 3 ]
  # `! [[ ]]` is silent on every bash (#670): errexit exempts a negated
  # command, so this pair never once failed. `grep -F` is the faithful
  # equivalent of a quoted `[[ == *…* ]]` -- a literal substring -- and
  # `refute` makes the absence enforced.
  refute grep -q -F -- 'SHARED 0xe ' <<<"$output"
  refute grep -q -F -- 'SHARED pipe ' <<<"$output"
}

@test "pipe-holders: Linux — the two ends of one pipeline are the same pipe" {
  # `sleep | cat`: the writer's stdout and the reader's stdin are one pipe, and
  # the inode is what says so.
  run awk -f "$HOLDERS" "$LINUX"
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep -F 'inode:631802')"
  [[ "$line" == *"sleep(pid 10, fd 1)"* ]]
  [[ "$line" == *"cat(pid 11, fd 0)"* ]]
}

@test "pipe-holders: says so when nothing is shared, rather than printing nothing" {
  # Silence and "nothing found" look identical, and one of them is a broken
  # instrument.
  run bash -c "printf 'p1\ncsh\nf3\ntPIPE\nn->0xaaa\n' | awk -f '$HOLDERS'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no pipe is held by more than one"* ]]
}

@test "forensics: one -F snapshot over all candidates, and no per-pid line cap" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"
  # A per-pid loop puts the two ends of a pipe in blocks taken at different
  # moments, which cannot be correlated. A cap cut the decisive line in the
  # 08-01 hang. Both are how the evidence was present and unusable.
  run grep -F 'lsof -F pcftDin -p "$pids"' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'pipe-holders.awk' "$workflow"
  [ "$status" -eq 0 ]
  run grep -E 'lsof -p "\$pid"' "$workflow"
  [ "$status" -ne 0 ]
  run grep -E 'if \(n <= 14\)|NR <= 4' "$workflow"
  [ "$status" -ne 0 ]
}
