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
  grep -qF -- "20 new message(s):" <<< "$output"
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

# --- AGMSG_SQLITE_OUTCOME_FILE (recording) path -------------------------
#
# agmsg_sqlite() takes a completely different branch when
# AGMSG_SQLITE_OUTCOME_FILE is set (_agmsg_sqlite_recording -- only the
# sync driver adapter sets this, scripts/internal/storage-sync-driver.sh),
# so the fix above does not automatically cover it: it needs, and got, its
# own copy of the same trailing-CR normalization. A codex review of the
# first version of this fix caught the gap. Reproduces via the same
# _stub_sqlite3_crlf, plus a second, fully synthetic stub
# (_stub_sqlite3_fixed) for deterministically exercising the ok/busy/failed
# classification without depending on real SQLITE_BUSY lock-contention
# timing.

@test "agmsg_sqlite (recording path): strips only the trailing CR, same as the non-recording path" {
  local stub outfile
  stub="$(_stub_sqlite3_crlf)"
  outfile="$BATS_TEST_TMPDIR/outcome"
  PATH="$stub:$PATH"
  run bash -c "source '$SCRIPTS/lib/storage.sh'; AGMSG_SQLITE_OUTCOME_FILE='$outfile' agmsg_sqlite ':memory:' 'SELECT 1; SELECT 2; SELECT 3;'"
  [ "$status" -eq 0 ]
  [ "$output" = $'1\n2\n3' ]
  [ "$(cat "$outfile")" = ok ]
}

@test "agmsg_sqlite (recording path): preserves a genuine mid-body CR under the same CRLF stub" {
  local stub outfile
  stub="$(_stub_sqlite3_crlf)"
  outfile="$BATS_TEST_TMPDIR/outcome"
  PATH="$stub:$PATH"
  run bash -c "source '$SCRIPTS/lib/storage.sh'; AGMSG_SQLITE_OUTCOME_FILE='$outfile' agmsg_sqlite ':memory:' \"SELECT 'x' || char(31) || 'a' || char(13) || 'b' || char(31) || 'id123';\""
  [ "$status" -eq 0 ]
  [ "$output" = $'x\x1fa\rb\x1fid123' ]
  [ "$(cat "$outfile")" = ok ]
}

# A stub that ignores the real database entirely and just emits FIXED
# stdout/stderr/exit-code content read back from two plain files -- for
# testing _agmsg_sqlite_recording's own ok/busy/failed classification and
# exit-status passthrough in isolation from any real SQL execution or lock
# timing. The desired bytes are written to files by the CALLER (ordinary
# $'...' quoting there, no heredoc-embedding hazards) rather than baked into
# the generated script's own text.
_stub_sqlite3_fixed() {
  local dir="$BATS_TEST_TMPDIR/fixedbin" stdout_file="$1" stderr_file="$2" exitcode="$3"
  mkdir -p "$dir"
  cat > "$dir/sqlite3" <<EOF
#!/usr/bin/env bash
cat "$stdout_file"
cat "$stderr_file" >&2
exit $exitcode
EOF
  chmod +x "$dir/sqlite3"
  printf '%s' "$dir"
}

@test "agmsg_sqlite (recording path): ok classification, outcome file, and exit code are unchanged" {
  local stub outfile stdout_file stderr_file
  stdout_file="$BATS_TEST_TMPDIR/out.txt"; stderr_file="$BATS_TEST_TMPDIR/err.txt"
  printf 'row1\nrow2\n' > "$stdout_file"
  printf '' > "$stderr_file"
  stub="$(_stub_sqlite3_fixed "$stdout_file" "$stderr_file" 0)"
  outfile="$BATS_TEST_TMPDIR/outcome"
  PATH="$stub:$PATH"
  run bash -c "source '$SCRIPTS/lib/storage.sh'; AGMSG_SQLITE_OUTCOME_FILE='$outfile' agmsg_sqlite ':memory:' 'irrelevant, the stub ignores it;'"
  [ "$status" -eq 0 ]
  [ "$output" = $'row1\nrow2' ]
  [ "$(cat "$outfile")" = ok ]
}

@test "agmsg_sqlite (recording path): busy classification, outcome file, exit code, and verbatim stderr are unchanged" {
  local stub outfile stdout_file stderr_file
  stdout_file="$BATS_TEST_TMPDIR/out.txt"; stderr_file="$BATS_TEST_TMPDIR/err.txt"
  printf '' > "$stdout_file"
  printf 'Error: database is locked\n' > "$stderr_file"
  stub="$(_stub_sqlite3_fixed "$stdout_file" "$stderr_file" 5)"
  outfile="$BATS_TEST_TMPDIR/outcome"
  PATH="$stub:$PATH"
  # --separate-stderr (bats-core, same idiom test_remote_sync.bats already
  # uses) so stdout and stderr can be asserted apart -- the sed fix touches
  # stdout only, so the classification text must arrive on $stderr
  # byte-for-byte, not just be classified correctly.
  run --separate-stderr bash -c "source '$SCRIPTS/lib/storage.sh'; AGMSG_SQLITE_OUTCOME_FILE='$outfile' agmsg_sqlite ':memory:' 'irrelevant, the stub ignores it;'"
  [ "$status" -eq 5 ]
  [ "$(cat "$outfile")" = busy ]
  [[ "$stderr" == *"Error: database is locked"* ]]
}

@test "agmsg_sqlite (recording path): failed classification, outcome file, exit code, and verbatim stderr are unchanged" {
  local stub outfile stdout_file stderr_file
  stdout_file="$BATS_TEST_TMPDIR/out.txt"; stderr_file="$BATS_TEST_TMPDIR/err.txt"
  printf '' > "$stdout_file"
  printf 'Error: near "not": syntax error\n' > "$stderr_file"
  stub="$(_stub_sqlite3_fixed "$stdout_file" "$stderr_file" 1)"
  outfile="$BATS_TEST_TMPDIR/outcome"
  PATH="$stub:$PATH"
  run --separate-stderr bash -c "source '$SCRIPTS/lib/storage.sh'; AGMSG_SQLITE_OUTCOME_FILE='$outfile' agmsg_sqlite ':memory:' 'irrelevant, the stub ignores it;'"
  [ "$status" -eq 1 ]
  [ "$(cat "$outfile")" = failed ]
  [[ "$stderr" == *"syntax error"* ]]
}

@test "agmsg_sqlite (recording path): busy classification survives a caller with -e/pipefail already on (storage-sync-driver.sh's own setting)" {
  # _agmsg_sqlite_recording is a plain function call, not a subshell -- it
  # runs IN the calling script's own shell, inheriting whatever `set -e` /
  # `set -o pipefail` that shell already has. storage-sync-driver.sh, the
  # ONLY real caller that ever sets AGMSG_SQLITE_OUTCOME_FILE, has
  # `set -euo pipefail` at its own top, so this is the actual condition in
  # production, not a hypothetical.
  #
  # A prior version of this fix guarded the pipeline with `pipeline ||
  # true` to keep a pipefail-inheriting caller's `set -e` from aborting
  # right there. That guard is safe on its own, but this call site ALSO
  # reads `${PIPESTATUS[0]}` afterward -- and PIPESTATUS is overwritten by
  # the very next command this shell runs, of any kind. With pipefail on,
  # the pipeline's own exit status became sqlite3's non-zero one, which is
  # exactly when `|| true` runs `true` -- so `${PIPESTATUS[0]}` was read
  # back as `true`'s (0), not sqlite3's, and every busy/failed call quietly
  # became "ok". Only a caller with pipefail already on triggers `|| true`
  # in the first place, which is why the tests above -- run from a plain
  # `bash -c` with no pipefail -- stayed green through this: they never
  # replicated the one caller shape that actually breaks it. Caught for
  # real by test_remote_sync.bats's busy-timeout contract test, which does
  # go through the real adapter and hence its `-o pipefail`.
  local stub outfile stdout_file stderr_file
  stdout_file="$BATS_TEST_TMPDIR/out.txt"; stderr_file="$BATS_TEST_TMPDIR/err.txt"
  printf '' > "$stdout_file"
  printf 'Error: database is locked\n' > "$stderr_file"
  stub="$(_stub_sqlite3_fixed "$stdout_file" "$stderr_file" 5)"
  outfile="$BATS_TEST_TMPDIR/outcome"
  PATH="$stub:$PATH"
  run --separate-stderr bash -c "set -euo pipefail; source '$SCRIPTS/lib/storage.sh'; AGMSG_SQLITE_OUTCOME_FILE='$outfile' agmsg_sqlite ':memory:' 'irrelevant, the stub ignores it;'"
  [ "$status" -eq 5 ]
  [ "$(cat "$outfile")" = busy ]
  [[ "$stderr" == *"Error: database is locked"* ]]
}
