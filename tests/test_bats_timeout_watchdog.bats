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
    body="$(_teardown_code "$f")"
    _drops_stubs <<<"$body" || bad="$bad $(basename "$f")"
  done
  [ -z "$bad" ] || { echo "own teardown keeps kill/sleep/wait stubs:$bad" >&2; return 1; }
}

# The code of a file's teardown(), without comments: a one-line teardown() { ...; } is
# that line alone, a multi-line one runs to the first closing brace at column 0.
_teardown_code() {
  awk '
    /^teardown\(\)/ {
      p = 1
      if ($0 ~ /\}[[:space:]]*$/ && $0 ~ /\{.*[^[:space:]{]/) { print; exit }
    }
    p { print }
    p && /^}/ { exit }
  ' "$1" | sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//'
}

# A real teardown_test_env call, or one `unset -f` that names all three functions.
_drops_stubs() {
  local line
  while IFS= read -r line; do
    case "$line" in
      *"unset -f"*kill*) case "$line" in *sleep*wait*|*wait*sleep*) return 0 ;; esac ;;
    esac
    if grep -qE '(^|[;{&|[:space:]])teardown_test_env([;}&|[:space:]]|$)' <<<"$line"; then
      return 0
    fi
  done
  return 1
}

@test "the teardown check sees through comments and one-line teardowns" {
  local d="$BATS_TEST_TMPDIR"
  printf '%s\n' 'teardown() {' '  # does not go through teardown_test_env' '  rm -rf x' '}' 'other() { teardown_test_env; }' > "$d/a.bats"
  if _drops_stubs <<<"$(_teardown_code "$d/a.bats")"; then return 1; fi
  printf '%s\n' 'teardown() { rm -rf x; }' 'other() { unset -f kill sleep wait; }' > "$d/b.bats"
  if _drops_stubs <<<"$(_teardown_code "$d/b.bats")"; then return 1; fi
  printf '%s\n' 'teardown() { teardown_test_env; }' > "$d/c.bats"
  _drops_stubs <<<"$(_teardown_code "$d/c.bats")"
  printf '%s\n' 'teardown() {' '  unset -f kill sleep wait 2>/dev/null || true' '  rm -rf x' '}' > "$d/d.bats"
  _drops_stubs <<<"$(_teardown_code "$d/d.bats")"
  printf '%s\n' 'teardown() {' '  unset -f kill sleep' '}' > "$d/e.bats"
  if _drops_stubs <<<"$(_teardown_code "$d/e.bats")"; then return 1; fi
}
