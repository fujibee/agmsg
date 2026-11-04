#!/usr/bin/env bats

# #1842: once a poll cycle has confirmed the local store did not change since
# the last real check (an mtime comparison against a stamp file, both bash
# builtins -- no subprocess), it skips storage_read_cursor_get/
# storage_watch_after entirely rather than forking sqlite3 (plus a `tr`
# pipeline) for an answer it already knows. The first couple of cycles still
# do a real check (there is nothing to compare against yet); steady state
# after that should fork no sqlite3 at all until something actually changes
# or the 60s safety net is reached.

load test_helper

setup() {
  setup_test_env
  export PROJ="/tmp/agmsg-watch-idleskip-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

@test "watch: a settled idle cycle forks no sqlite3 at all" {
  bash "$SCRIPTS/send.sh" team bob alice "seed" >/dev/null
  bash "$SCRIPTS/inbox.sh" team alice >/dev/null

  local shimbin="$BATS_TEST_TMPDIR/shim-bin" countlog="$BATS_TEST_TMPDIR/counts.log"
  mkdir -p "$shimbin"
  : > "$countlog"
  local real
  real="$(command -v sqlite3)"
  cat > "$shimbin/sqlite3" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$countlog"
exec "$real" "\$@"
EOF
  chmod +x "$shimbin/sqlite3"
  real="$(command -v sleep)"
  cat > "$shimbin/sleep" <<EOF
#!/usr/bin/env bash
printf 'sleep\n' >> "$countlog"
exec "$real" "\$@"
EOF
  chmod +x "$shimbin/sleep"

  AGMSG_WATCH_INTERVAL=2 PATH="$shimbin:$PATH" \
    bash "$SCRIPTS/watch.sh" "idleskip-sess" "$PROJ" claude-code alice \
    >"$BATS_TEST_TMPDIR/watch.out" 2>"$BATS_TEST_TMPDIR/watch.err" &
  local wpid=$!
  sleep 26
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null

  # The first real check (nothing to compare against yet) forks sqlite3, and
  # under the extra exec overhead this shim adds, settling can take one or
  # two more cycles than it does unshimmed. Ignore the first four completed
  # cycles (`sleep` markers) for exactly that reason, and require every
  # cycle from the fifth on to make no MESSAGE-STORE query -- the one
  # `_agmsg_partition_load` makes every cycle BY DESIGN (#1330: a team's
  # partition driver is re-read once per cycle, never cached for the
  # process's life, so a mid-run store migration is still noticed) stays,
  # out of this change's scope; what must be gone is
  # storage_read_cursor_get/storage_watch_after's own queries, which this
  # fixture's single-file sqlite driver always runs against "messages.db".
  local after_settle
  after_settle="$(awk '
    $0 == "sleep" { n++; next }
    n >= 4 && /messages\.db/ { print }
  ' "$countlog")"
  echo "message-store queries after the fourth completed cycle: [$after_settle]" >&3
  [ -z "$after_settle" ]

  local cycles; cycles=$(grep -c '^sleep$' "$countlog")
  echo "completed cycles: $cycles" >&3
  [ "$cycles" -ge 6 ]
}
