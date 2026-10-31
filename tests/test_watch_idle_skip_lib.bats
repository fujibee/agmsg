#!/usr/bin/env bats

# Unit tests for the watcher's idle-skip checkpoint maps
# (lib/watch-idle-skip.sh, #1842). These pin down, deterministically, the
# three correctness properties a full-watcher test cannot isolate from
# timing: per-PAIR (not per-team) isolation, a multi-line fingerprint
# surviving the newline-separated map it is stored in, and the safety-net
# clock being per-pair too.

load test_helper

setup() {
  setup_test_env
  source "$SCRIPTS/lib/compat.sh"
  source "$SCRIPTS/lib/watch-idle-skip.sh"
  _AGMSG_WATCH_ARMED_FP=""
  _AGMSG_WATCH_FORCE_AT_MAP=""
  _AGMSG_WATCH_DB_PATH_MAP=""
}

@test "idle-skip: an armed fingerprint for one pair is invisible to another pair of the same team" {
  _watch_armed_fp_set "team:alice" "111 222 /x/messages.db"
  ! _watch_armed_fp_get "team:bob"
}

@test "idle-skip: a multi-line fingerprint (db + db-wal) round-trips through the map intact" {
  # Two stat lines, as a real db+wal pair produces -- the exact shape whose
  # internal newline, before this fix flattened it, got read back as only
  # its first line (the second line was indistinguishable from a second map
  # record and silently dropped).
  local real_fp
  real_fp="$(_watch_fingerprint "$SCRIPTS/lib/compat.sh" "$SCRIPTS/lib/watch-idle-skip.sh")"
  case "$real_fp" in
    *'|'*) : ;;
    *) echo "fingerprint of two real files did not flatten to a single '|'-joined line: [$real_fp]" >&3; false ;;
  esac
  _watch_armed_fp_set "team:alice" "$real_fp"
  _watch_armed_fp_get "team:alice"
  [ "$_WATCH_ARMED_FP" = "$real_fp" ]
}

@test "idle-skip: dropping one pair's armed fingerprint leaves a sibling pair's untouched" {
  _watch_armed_fp_set "team:alice" "fp-alice"
  _watch_armed_fp_set "team:bob" "fp-bob"
  _watch_armed_fp_drop "team:alice"
  refute _watch_armed_fp_get "team:alice"
  _watch_armed_fp_get "team:bob"
  [ "$_WATCH_ARMED_FP" = "fp-bob" ]
}

@test "idle-skip: the safety-net clock is per pair, not per team" {
  _watch_safety_mark "team:alice"
  # alice was just marked (0s ago): not due.
  refute _watch_safety_due "team:alice"
  # bob, in the SAME team, was never marked: due immediately. A team-wide
  # clock (the #1846 round-1 bug) would have had alice's mark satisfy bob's
  # check too.
  _watch_safety_due "team:bob"
}

@test "idle-skip: a pair that was never marked is due immediately" {
  _watch_safety_due "team:never-checked"
}
