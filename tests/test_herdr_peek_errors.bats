#!/usr/bin/env bats

# Exercise the shared plain/styled read path without a live terminal, database,
# or agent process. All fixture files live in Bats' per-test temporary directory.
setup() {
  export HERDR_TEST_STDOUT="$BATS_TEST_TMPDIR/stdout"
  export HERDR_TEST_STDERR="$BATS_TEST_TMPDIR/stderr"
  export HERDR_TEST_RC=1
  export HERDR_TEST_ARGV="$BATS_TEST_TMPDIR/argv"
  export HERDR_TEST_DRIVER="$BATS_TEST_DIRNAME/../scripts/drivers/terminals/herdr/ops.sh"
  : > "$HERDR_TEST_STDOUT"
  : > "$HERDR_TEST_STDERR"
  mkdir "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$HERDR_TEST_ARGV"
cat "$HERDR_TEST_STDOUT"
cat "$HERDR_TEST_STDERR" >&2
exit "$HERDR_TEST_RC"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/herdr"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

_assert_error() {
  local expected="$1" mode rc out err
  out="$BATS_TEST_TMPDIR/out"; err="$BATS_TEST_TMPDIR/err"
  for mode in terminal_peek terminal_peek_styled; do
    rc=0
    bash -euo pipefail -c 'source "$HERDR_TEST_DRIVER"; "$1" "/mock/herdr.sock:w1:p4" --lines 7' _ "$mode" > "$out" 2> "$err" || rc=$?
    [ "$rc" -eq "$expected" ]
    [ ! -s "$out" ]
    # Both original channels remain diagnostics, even when only one is parsed.
    if [ -s "$HERDR_TEST_STDOUT" ]; then grep -qF -f "$HERDR_TEST_STDOUT" "$err"; fi
    if [ -s "$HERDR_TEST_STDERR" ]; then grep -qF -f "$HERDR_TEST_STDERR" "$err"; fi
    if [ "$expected" -eq 12 ]; then
      grep -qF 'the terminal reports it no longer exists' "$err"
    else
      [ "$(grep -cF 'the terminal reports it no longer exists' "$err")" -eq 0 ]
    fi
    printf 'pane\nread\nw1:p4\n--source\nrecent\n--lines\n7\n' > "$BATS_TEST_TMPDIR/expected-argv"
    if [ "$mode" = terminal_peek_styled ]; then printf '%s\n' --format ansi >> "$BATS_TEST_TMPDIR/expected-argv"; fi
    cmp "$BATS_TEST_TMPDIR/expected-argv" "$HERDR_TEST_ARGV"
  done
}

@test "herdr peek errors: stderr-only pane_not_found is confirmed gone (#1317)" {
  printf '%s\n' '{"error":{"code":"pane_not_found","message":"pane w1:p4 not found"},"id":"cli:pane:read"}' > "$HERDR_TEST_STDERR"
  _assert_error 12
}

@test "herdr peek errors: stderr pane matches the bare part of a qualified id" {
  printf '%s\n' '{"error":{"code":"pane_not_found","pane":"w1:p4"}}' > "$HERDR_TEST_STDERR"
  _assert_error 12
}

@test "herdr peek errors: stdout pane_not_found remains supported" {
  printf '%s\n' '{"error":{"code":"pane_not_found","pane":"w1:p4"}}' > "$HERDR_TEST_STDOUT"
  _assert_error 12
}

@test "herdr peek errors: a stdout code takes precedence over stderr absence" {
  printf '%s\n' '{"error":{"code":"read_failed"}}' > "$HERDR_TEST_STDOUT"
  printf '%s\n' '{"error":{"code":"pane_not_found","pane":"w1:p4"}}' > "$HERDR_TEST_STDERR"
  _assert_error 11
}

@test "herdr peek errors: stdout absence retains its own pane when stderr disagrees" {
  printf '%s\n' '{"error":{"code":"pane_not_found","pane":"w9:p9"}}' > "$HERDR_TEST_STDOUT"
  printf '%s\n' '{"error":{"code":"pane_not_found","pane":"w1:p4"}}' > "$HERDR_TEST_STDERR"
  _assert_error 11
}

@test "herdr peek errors: a stderr claim for another pane remains undecided" {
  printf '%s\n' '{"error":{"code":"pane_not_found","pane":"w9:p9"}}' > "$HERDR_TEST_STDERR"
  _assert_error 11
}

@test "herdr peek errors: stdout without a code falls back without carrying its pane" {
  printf '%s\n' '{"error":{"pane":"w9:p9"}}' > "$HERDR_TEST_STDOUT"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$HERDR_TEST_STDERR"
  _assert_error 12
}

@test "herdr peek errors: malformed stdout can fall back to structured stderr" {
  printf '%s\n' '{broken' > "$HERDR_TEST_STDOUT"
  printf '%s\n' '{"error":{"code":"pane_not_found","pane":"w1:p4"}}' > "$HERDR_TEST_STDERR"
  _assert_error 12
}

@test "herdr peek errors: non-JSON stderr mentioning pane_not_found is undecided" {
  printf '%s\n' 'PermissionDenied: cannot check pane_not_found' > "$HERDR_TEST_STDERR"
  _assert_error 11
}

@test "herdr peek errors: malformed stderr JSON is undecided" {
  printf '%s\n' '{"error":{"code":"pane_not_found"}' > "$HERDR_TEST_STDERR"
  _assert_error 11
}

@test "herdr peek errors: unrelated stderr code and quoted message are undecided" {
  printf '%s\n' "{\"error\":{\"code\":\"read_failed\",\"message\":\"isn't pane_not_found\"}}" > "$HERDR_TEST_STDERR"
  _assert_error 11
}

@test "herdr peek errors: renamed and non-text stderr codes are undecided" {
  local code
  for code in '"PaneNotFound"' 'null' '12' '["pane_not_found"]'; do
    printf '{"error":{"code":%s}}\n' "$code" > "$HERDR_TEST_STDERR"
    _assert_error 11
  done
}

@test "herdr peek errors: no diagnostic is undecided" {
  _assert_error 11
}

@test "herdr peek errors: successful content stays verbatim despite stderr error JSON" {
  export HERDR_TEST_RC=0
  printf 'visible text\n\n' > "$HERDR_TEST_STDOUT"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$HERDR_TEST_STDERR"
  local mode
  for mode in terminal_peek terminal_peek_styled; do
    bash -euo pipefail -c 'source "$HERDR_TEST_DRIVER"; "$1" w1:p4' _ "$mode" > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err"
    cmp "$HERDR_TEST_STDOUT" "$BATS_TEST_TMPDIR/out"
    [ ! -s "$BATS_TEST_TMPDIR/err" ]
  done
}
