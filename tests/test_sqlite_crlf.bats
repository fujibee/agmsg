#!/usr/bin/env bats

# Regression coverage for a Windows-only sqlite3.exe behavior that this
# machine (Linux) cannot reproduce on its own: multi-row SELECT output
# separates rows with \r\n, not \n. Measured on real Windows hardware
# (sqlite3.exe 3.53.4) and reported against inbox.sh's mark-as-read step --
# see scripts/lib/storage.sh's agmsg_sqlite() for the full writeup. This
# file exercises the fix with a PATH-shimmed sqlite3 stub that reproduces
# the \r\n row separator deterministically on Linux, the same "wrapper
# script ahead of the real binary on PATH" technique test_watch_once.bats
# already uses for its slow-awk shim.
#
# No issue number yet -- this was found independently of #777 while
# verifying #777's own fix on Windows hardware, and has not been filed
# upstream.

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# A wrapper named `sqlite3`, placed ahead of the real one on PATH, that
# behaves exactly like the real binary except every line of its stdout
# gets a synthetic \r appended right before the \n -- simulating the \r\n
# Windows' sqlite3.exe emits at each row boundary.
#
# The real binary's path is resolved HERE, before this directory is ever
# prepended to PATH, and baked into the wrapper as a literal exec target.
# Mirrors test_watch_once.bats's `_slow_startup_path` awk shim exactly for
# this reason: a lookup done INSIDE the wrapper, after PATH already
# includes this directory, would resolve back to the wrapper itself.
_stub_sqlite3_crlf() {
  local dir="$BATS_TEST_TMPDIR/crlfbin" real
  real="$(command -v sqlite3)"
  mkdir -p "$dir"
  cat > "$dir/sqlite3" <<EOF
#!/usr/bin/env bash
set -o pipefail
"$real" "\$@" | sed 's/\$/\r/'
EOF
  chmod +x "$dir/sqlite3"
  printf '%s' "$dir"
}

# PATH is exported directly in THIS test's own process (each @test already
# runs in its own bash invocation under bats, so there is nothing to
# restore afterward) rather than threaded through a nested `bash -c
# "...\$PATH..."` string -- that nesting nearly shipped with a nested-quote
# bug where the inner $PATH never actually expanded (nested single quotes
# inside the outer double-quoted script text stayed literal), and every
# call under it failed with "command not found" for a completely unrelated
# reason.
@test "agmsg_sqlite: strips only the trailing CR Windows' sqlite3.exe adds at each row boundary" {
  local stub
  stub="$(_stub_sqlite3_crlf)"
  PATH="$stub:$PATH"
  run bash -c "source '$SCRIPTS/lib/storage.sh'; agmsg_sqlite ':memory:' 'SELECT 1; SELECT 2; SELECT 3;'"
  [ "$status" -eq 0 ]
  [ "$output" = $'1\n2\n3' ]
}

@test "agmsg_sqlite: preserves a genuine mid-body CR under the same CRLF stub" {
  local stub
  stub="$(_stub_sqlite3_crlf)"
  PATH="$stub:$PATH"
  # Shaped like inbox.sh's own row-building SELECT: field, then a body
  # containing an embedded, UNESCAPED char(13), then more fields -- every
  # row-building SELECT in this codebase already replaces char(10) in the
  # body with a literal "\n", but char(13) is untouched, so this exact byte
  # sequence is real and reachable, not a synthetic edge case.
  run bash -c "source '$SCRIPTS/lib/storage.sh'; agmsg_sqlite ':memory:' \"SELECT 'x' || char(31) || 'a' || char(13) || 'b' || char(31) || 'id123';\""
  [ "$status" -eq 0 ]
  [ "$output" = $'x\x1fa\rb\x1fid123' ]
}

@test "agmsg_sqlite: a failing statement still reports non-zero under the CRLF stub" {
  local stub
  stub="$(_stub_sqlite3_crlf)"
  PATH="$stub:$PATH"
  run bash -c "source '$SCRIPTS/lib/storage.sh'; agmsg_sqlite ':memory:' 'not valid sql;'"
  [ "$status" -ne 0 ]
}

@test "inbox.sh: a full backlog is marked read in one run under the CRLF stub" {
  local stub
  stub="$(_stub_sqlite3_crlf)"
  bash "$SCRIPTS/join.sh" crlfteam alice claude-code /tmp/project-crlf >/dev/null
  bash "$SCRIPTS/join.sh" crlfteam bob claude-code /tmp/project-crlf >/dev/null
  local n
  for n in $(seq 1 20); do
    bash "$SCRIPTS/send.sh" crlfteam bob alice "CRLF-$n" >/dev/null
  done

  PATH="$stub:$PATH"
  run bash "$SCRIPTS/inbox.sh" crlfteam alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"20 new message(s):"* ]]
  for n in $(seq 1 20); do
    [[ "$output" == *"CRLF-$n"* ]]
  done

  # The real symptom: with the pre-fix agmsg_sqlite, only the LAST id in a
  # multi-row unread scan kept a clean (unmangled) trailing field, so all
  # but one mark-as-read update silently matched no real msg_id and every
  # other message stayed unread. Fixed, the whole backlog clears.
  local left
  # `grep -c .` exits 1 when the count is 0 (no matching lines) -- correct
  # and expected here, but bats runs test bodies under `set -e`, so without
  # `|| true` that exit status would abort the test right at this
  # assignment before the assertion below ever ran.
  left="$(bash -c '
    source "'"$SCRIPTS"'/lib/storage.sh"
    agmsg_storage_load
    storage_list_unread crlfteam alice
  ' | grep -c . || true)"
  [ "$left" -eq 0 ]
}
