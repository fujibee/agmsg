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
      if [ "$cmd" = dirname ]; then
        printf 'if [ "${1:-}" = %q ]; then\n' "$SCRIPTS/lib/storage.sh"
        printf "  printf '@storage-path\\\\n' >> '%s'\n" "$countlog"
        printf 'fi\n'
      fi
      printf "exec '%s' \"\$@\"\n" "$real"
    } > "$shimbin/$cmd"
    chmod +x "$shimbin/$cmd"
  done

  # Observe actual cache misses in this disposable installation. These
  # wrappers delegate unchanged and only append fixed semantic markers via
  # a builtin; their markers are never counted as external processes.
  cat >> "$SCRIPTS/lib/actas-lock.sh" <<'SH'
eval "$(declare -f _agmsg_id_key_or_legacy | sed '1s/_agmsg_id_key_or_legacy/_watch_count_real_id_key/')"
_agmsg_id_key_or_legacy() {
  if [ "${FUNCNAME[1]:-}" = _actas_lock_primitives_into ]; then
    printf '@primitive-resolution\n' >> "$AGMSG_WATCH_PROCESS_COUNT_LOG"
  fi
  _watch_count_real_id_key "$@"
}
SH
  cat >> "$SCRIPTS/lib/driver-registry.sh" <<'SH'
eval "$(declare -f agmsg_driver_for_team | sed '1s/agmsg_driver_for_team/_watch_count_real_driver_for_team/')"
agmsg_driver_for_team() {
  if [ "$1" = partition ]; then
    if [ "${_AGMSG_POLL_CYCLE_EPOCH:-0}" -gt 0 ]; then
      printf '@partition-warm:%s\n' "$_AGMSG_POLL_CYCLE_EPOCH" >> "$AGMSG_WATCH_PROCESS_COUNT_LOG"
    else
      printf '@partition-fresh\n' >> "$AGMSG_WATCH_PROCESS_COUNT_LOG"
    fi
  fi
  _watch_count_real_driver_for_team "$@"
}
SH

  AGMSG_WATCH_PROCESS_COUNT_LOG="$countlog" AGMSG_WATCH_INTERVAL=2 PATH="$shimbin:$PATH" \
    bash "$SCRIPTS/watch.sh" "proccount-sess" "$PROJ" claude-code alice \
    >"$BATS_TEST_TMPDIR/watch.out" 2>"$BATS_TEST_TMPDIR/watch.err" &
  local wpid=$!
  sleep 14
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null

  # The first sleep starts only after startup and the first, cold poll. Count
  # complete sleep-to-sleep intervals after that boundary: each includes the
  # next poll and one sleep invocation, independent of machine speed. Buffer
  # each interval until its closing sleep marker so an interrupted final poll
  # cannot enter the numerator without a corresponding completed cycle.
  local steadylog="$BATS_TEST_TMPDIR/steady-counts.log"
  awk '
    $0 == "sleep" {
      if (started) printf "%ssleep\n", cycle
      started = 1
      cycle = ""
      next
    }
    started { cycle = cycle $0 "\n" }
  ' "$countlog" > "$steadylog"
  local processlog="$BATS_TEST_TMPDIR/steady-processes.log"
  awk '$0 !~ /^@/' "$steadylog" > "$processlog"
  local total cycles; total=$(wc -l < "$processlog" | tr -d ' ')
  cycles=$(grep -c '^sleep$' "$steadylog" || true)
  echo "forked sqlite3/tr/awk/sed/dirname/head/mktemp/paste/sleep: $total over $cycles complete idle cycles" >&3
  sort "$processlog" | uniq -c | sort -rn >&3
  [ "$cycles" -ge 2 ]
  local per_cycle=$((total / cycles))
  echo "per cycle: $per_cycle" >&3
  # Keep the existing 55-process budget. The old startup-inclusive averages
  # (45 with both cache stages, 61 with only the first) motivated this cap,
  # but are not steady-state measurements. Compare the exact total rather
  # than letting integer division round an over-budget average down to 55.
  [ "$total" -le "$((55 * cycles))" ]

  # Each probe must actually see cold work before the first sleep: a broken
  # wrapper or a misspelled shim target cannot pass by reporting no work.
  local probe
  for probe in @primitive-resolution @storage-path @partition-warm: @partition-fresh; do
    awk -v probe="$probe" '
      $0 == "sleep" { exit }
      index($0, probe) == 1 { seen = 1 }
      END { exit !seen }
    ' "$countlog" || { echo "cold cache probe was not observed: $probe" >&3; return 1; }
  done

  # Cached actas primitives and the storage directory require no warm-cycle
  # resolution. The partition selector MUST resolve once per positive epoch,
  # while delivery admission deliberately forces two epoch-zero fresh reads
  # before and after the claim transaction. Test both reuse and freshness in
  # each complete interval, without lowering 55 to an arbitrary new budget.
  awk '
    /^@primitive-resolution$/ { primitive++ }
    /^@storage-path$/ { directory++ }
    /^@partition-warm:/ { warm++ }
    /^@partition-fresh$/ { fresh++ }
    $0 == "sleep" {
      cycle++
      printf "cache work cycle %d: primitives=%d storage-path=%d partition-warm=%d partition-fresh=%d\n",
        cycle, primitive, directory, warm, fresh
      if (primitive != 0 || directory != 0 || warm != 1 || fresh != 2) failed = 1
      primitive = directory = warm = fresh = 0
    }
    END { exit failed }
  ' "$steadylog" >&3
}
