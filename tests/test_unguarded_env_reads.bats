#!/usr/bin/env bats

# The checker that stops `scripts/**/*.sh` growing a read of an environment
# variable with no default (#1129).
#
# It exists because the SUITE cannot do this job. Every entry point that reaches
# those files runs `set -euo pipefail`; tests/test_helper.bash sets no shell
# options at all, so a read that is only fatal under `-u` never fires inside a
# test. Measured: forcing `set -u` into the shared helper and running all 102
# suites produced 8 reds and not one of them was a defect in scripts/ -- and
# `test_terminal_registry` was 129/129 GREEN on the tree that still contained
# the one confirmed defect of this class (#1126).
#
# So the checker is static, and it is exercised against fixture trees here --
# the difference between a guard that has been shown to fire and one that has
# only ever seen a clean input.

CHECK="${BATS_TEST_DIRNAME}/../.github/scripts/check-unguarded-env-reads.sh"
BASELINE="${BATS_TEST_DIRNAME}/../.github/unguarded-env-reads-baseline"

@test "unguarded-env-reads: the real tree sits at its baseline" {
  run bash "$CHECK"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -q 'at the baseline'
}

@test "unguarded-env-reads: the baseline is a number, and matches what is there" {
  n="$(tr -d '[:space:]' < "$BASELINE")"
  case "$n" in ''|*[!0-9]*) echo "baseline is not a number: [$n]" >&2; return 1 ;; esac
  run bash "$CHECK"
  printf '%s\n' "$output" | grep -q -F -- "($n)"
}

@test "unguarded-env-reads: the shape that shipped in #1126 is reported and fails" {
  # The real one, reduced: a driver reading \$TMUX with no default, in a
  # function that does not guard it. This is the line that killed the tmux
  # label search while every test stayed green.
  fixture="$BATS_TEST_TMPDIR/f1"; mkdir -p "$fixture"
  cat > "$fixture/ops.sh" <<'EOF'
terminal_find_by_label() {
  local label="$1" sock
  sock="${TMUX%%,*}"
  printf '%s\n' "$sock"
}
EOF
  printf '0\n' > "$BATS_TEST_TMPDIR/base0"
  run env AGMSG_ENV_READS_BASELINE="$BATS_TEST_TMPDIR/base0" bash "$CHECK" "$fixture"
  [ "$status" -eq 1 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -q 'ops.sh:3: \$TMUX'
}

@test "unguarded-env-reads: the same read WITH a default is not reported" {
  # The partner. Without it, "report every \$NAME" also passes the test above,
  # and the check would fire on correct code forever.
  fixture="$BATS_TEST_TMPDIR/f2"; mkdir -p "$fixture"
  cat > "$fixture/ops.sh" <<'EOF'
terminal_find_by_label() {
  local sock
  sock="${TMUX:-}"; sock="${sock%%,*}"
  printf '%s\n' "$sock"
}
EOF
  printf '0\n' > "$BATS_TEST_TMPDIR/base0b"
  run env AGMSG_ENV_READS_BASELINE="$BATS_TEST_TMPDIR/base0b" bash "$CHECK" "$fixture"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "unguarded-env-reads: a read guarded EARLIER IN THE SAME FUNCTION is not reported" {
  # This is how #1126 was actually fixed, and it is the clause that lets the
  # count go DOWN again. Without it the count was 147 before the defect, 147
  # with it, and 147 after the fix -- a number that never moves is not a check.
  fixture="$BATS_TEST_TMPDIR/f3"; mkdir -p "$fixture"
  cat > "$fixture/ops.sh" <<'EOF'
terminal_find_by_label() {
  local sock
  [ -n "${TMUX:-}" ] || return 10
  sock="${TMUX%%,*}"
  printf '%s\n' "$sock"
}
EOF
  printf '0\n' > "$BATS_TEST_TMPDIR/base0c"
  run env AGMSG_ENV_READS_BASELINE="$BATS_TEST_TMPDIR/base0c" bash "$CHECK" "$fixture"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "unguarded-env-reads: the guard does NOT carry into the next function" {
  # The limit of the clause above, pinned so nobody widens it by accident: a
  # guard protects the reads below it in ITS function and nothing else.
  fixture="$BATS_TEST_TMPDIR/f4"; mkdir -p "$fixture"
  cat > "$fixture/ops.sh" <<'EOF'
guarded_one() {
  [ -n "${TMUX:-}" ] || return 10
  printf '%s\n' "${TMUX%%,*}"
}
other_one() {
  printf '%s\n' "${TMUX%%,*}"
}
EOF
  printf '0\n' > "$BATS_TEST_TMPDIR/base0d"
  run env AGMSG_ENV_READS_BASELINE="$BATS_TEST_TMPDIR/base0d" bash "$CHECK" "$fixture"
  [ "$status" -eq 1 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -q 'ops.sh:6: \$TMUX'
  # Not `refute` (this file loads no helper) and not `! grep` (a non-last `!`
  # does not fail a bats test on bash 3.2 -- the very shape the sibling checker
  # exists to stop). An `if` that returns is enforced on both shells.
  if printf '%s\n' "$output" | grep -q 'ops.sh:3:'; then
    echo "the guarded read was reported too:" >&2; echo "$output" >&2; return 1
  fi
}

@test "unguarded-env-reads: a variable the file ASSIGNS itself is not an environment read" {
  fixture="$BATS_TEST_TMPDIR/f5"; mkdir -p "$fixture"
  cat > "$fixture/ops.sh" <<'EOF'
SCRIPT_DIR="$(dirname "$0")"
use_it() { printf '%s\n' "$SCRIPT_DIR"; }
EOF
  printf '0\n' > "$BATS_TEST_TMPDIR/base0e"
  run env AGMSG_ENV_READS_BASELINE="$BATS_TEST_TMPDIR/base0e" bash "$CHECK" "$fixture"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "unguarded-env-reads: scanning nothing is not a pass" {
  # "0 findings" and "never opened the tree" look identical in a count. They
  # must not.
  empty="$BATS_TEST_TMPDIR/empty"; mkdir -p "$empty"
  run bash "$CHECK" "$empty"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'not a clean tree'
}

@test "unguarded-env-reads: an unreadable baseline is an error, not a pass" {
  run env AGMSG_ENV_READS_BASELINE="$BATS_TEST_TMPDIR/nope" bash "$CHECK"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'no readable baseline'
}
