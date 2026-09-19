#!/usr/bin/env bats

# One test, capping how many external commands a watch.sh poll cycle forks
# while genuinely idle (a store that exists and is already caught up, not the
# "no store yet" short-circuit) -- the case the fleet spends nearly all of its
# time in. Covers #1330's two stages:
#
#   first stage:  skip the mktemp + `sqlite3 :memory:` json_each/json_extract
#                 reformat pass when there is no real new message_sent row (a
#                 cursor-only page was still paying for it every cycle), and
#                 cache the per-(team,agent) primitives behind the actas lock
#                 path (team_id, member_id, the two name-encodings) for the
#                 life of the process instead of recomputing them via a fresh
#                 sqlite3/tr fork on every single cycle.
#
#   second stage: cache a team's storage partition driver too, but only for
#                 the CURRENT poll cycle (never the process lifetime -- see
#                 _agmsg_partition_load's comment in lib/storage.sh: caching
#                 it for the process life missed a real migrate-team-store.sh
#                 scenario, review #1329 round 2), and memoize
#                 agmsg_storage_dir (a value that genuinely cannot change for
#                 the life of the process). Both warmed as plain statements in
#                 this loop, and storage.sh gained a double-source guard after
#                 resolve-project.sh's own unconditional re-source of it was
#                 found silently wiping both caches back to cold every cycle.

load test_helper

setup() {
  setup_test_env
  export PROJ="/tmp/agmsg-watch-proccount-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

@test "watch: an idle, caught-up poll cycle forks well under the pre-#1321 baseline" {
  # Seed one message and mark it read FIRST, so the watcher starts in the
  # realistic "store exists, caught up" state rather than the "no store yet"
  # short-circuit -- a mistake caught and fixed once already during this
  # work's own planning (see the design notes referenced from #1321).
  bash "$SCRIPTS/send.sh" team bob alice "seed" >/dev/null
  bash "$SCRIPTS/inbox.sh" team alice >/dev/null

  local shimbin="$BATS_TEST_TMPDIR/shim-bin" countlog="$BATS_TEST_TMPDIR/counts.log"
  mkdir -p "$shimbin"
  : > "$countlog"
  local cmd real
  for cmd in sqlite3 tr awk sed dirname head mktemp paste sleep; do
    real="$(command -v "$cmd")"
    {
      printf '#!/usr/bin/env bash\n'
      printf "printf '%%s\\\\n' '%s' >> '%s'\n" "$cmd" "$countlog"
      printf "exec '%s' \"\$@\"\n" "$real"
    } > "$shimbin/$cmd"
    chmod +x "$shimbin/$cmd"
  done

  AGMSG_WATCH_INTERVAL=2 PATH="$shimbin:$PATH" \
    bash "$SCRIPTS/watch.sh" "proccount-sess" "$PROJ" claude-code alice \
    >"$BATS_TEST_TMPDIR/watch.out" 2>"$BATS_TEST_TMPDIR/watch.err" &
  local wpid=$!
  sleep 14
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null

  # Divide by the OBSERVED sleep count, not an assumed wall-clock/interval
  # division: `sleep` is itself shimmed above, so this is the same cycle a
  # completed "sleep $INTERVAL" at the bottom of the poll loop actually saw,
  # immune to how many cycles a loaded machine fit into the fixed window.
  local total cycles; total=$(wc -l < "$countlog" | tr -d ' ')
  cycles=$(grep -c '^sleep$' "$countlog")
  echo "forked sqlite3/tr/awk/sed/dirname/head/mktemp/paste: $total over $cycles idle cycles" >&3
  sort "$countlog" | uniq -c | sort -rn >&3
  [ "$cycles" -ge 2 ]
  local per_cycle=$((total / cycles))
  echo "per cycle: $per_cycle" >&3
  # Measured (this change, isolated bats env, several runs): roughly
  # 45-55/cycle after both stages above, against roughly 85-95/cycle on the
  # code before #1330. Capped with headroom above the optimized figure for
  # ordinary variance, and well under the pre-#1330 baseline so a regression
  # back to it still fails this.
  [ "$per_cycle" -le 70 ]
}
