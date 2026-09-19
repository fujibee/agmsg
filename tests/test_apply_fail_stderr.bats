#!/usr/bin/env bats

# `_sqlite_sync_apply_fail` must not take the shell's stderr with it.
#
# It closes fd 3 and discards whatever closing an already-closed fd would say.
# Written as `exec 3<&- 2>/dev/null`, with no command word, the redirection is
# not scoped to anything -- bash applies it to the shell itself, permanently.
# Every later `>&2` in that process goes to /dev/null.
#
# The path this sits on is the failure path, so the diagnostics it silences are
# the ones a failing apply is about to print. The first casualty is the message
# #911 added, naming which check returned 13. Reported by @JoelMitz.

setup() {
  SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"
}

@test "apply-fail: closing fd 3 does not redirect the shell's stderr (#911)" {
  # Runs the driver's OWN definition, not a copy of it: the function is nested
  # inside storage_sync_apply_pull and cannot be sourced, so its body is lifted
  # out of the file by line range and defined here. A copy would keep passing
  # while the driver regressed, which is the whole failure this test is about.
  local first last body
  first="$(grep -n '_sqlite_sync_apply_fail() {' "${SCRIPTS}/drivers/storage/sqlite-sync.sh" | head -1 | cut -d: -f1)"
  [ -n "$first" ]
  last="$(awk -v s="$first" 'NR>s && /^  \}$/ { print NR; exit }' "${SCRIPTS}/drivers/storage/sqlite-sync.sh")"
  [ -n "$last" ]
  body="$(sed -n "${first},${last}p" "${SCRIPTS}/drivers/storage/sqlite-sync.sh")"

  run bash -c "
    jq_err=/dev/null; sql_file=/dev/null
    $body
    _sqlite_sync_apply_fail
    echo 'stderr-after-close' >&2
  "
  [ "$status" -eq 0 ]
  grep -q "stderr-after-close" <<<"$output"
}

@test "apply-fail: the driver closes fd 3 in a scoped block, not bare exec" {
  # The regression is one character of syntax, so the guard is on the syntax.
  # A bare `exec <redirect>` with no command word anywhere in this file would
  # take the shell's stderr the same way.
  run grep -nE '^\s*exec [0-9]*[<>][&-]* +[0-9]*>' "${SCRIPTS}/drivers/storage/sqlite-sync.sh"
  [ "$status" -ne 0 ]
}
