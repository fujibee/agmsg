#!/usr/bin/env bats

# Unit tests for the watcher's idle-skip checkpoint maps
# (lib/watch-idle-skip.sh, #1842). These pin down, deterministically, the
# correctness properties a full-watcher test cannot isolate from timing:
# per-PAIR (not per-team) isolation, a multi-line fingerprint surviving the
# newline-separated map it is stored in, the safety-net clock being per-pair
# too, and (review round 2) a batched fingerprint surviving a same-second
# write and a stat failure never being confused with a known-absent path.

load test_helper

setup() {
  setup_test_env
  source "$SCRIPTS/lib/compat.sh"
  source "$SCRIPTS/lib/watch-idle-skip.sh"
  _AGMSG_WATCH_ARMED_FP=""
  _AGMSG_WATCH_FORCE_AT_MAP=""
  _AGMSG_WATCH_DB_PATH_MAP=""
  _AGMSG_WATCH_PATH_FP=""
}

@test "idle-skip: an armed fingerprint for one pair is invisible to another pair of the same team" {
  _watch_armed_fp_set "team:alice" "111 222 /x/messages.db"
  refute _watch_armed_fp_get "team:bob"
}

@test "idle-skip: a batched fingerprint covers every requested path in one stat call" {
  local f1="$BATS_TEST_TMPDIR/a" f2="$BATS_TEST_TMPDIR/b"
  printf 'x' > "$f1"
  printf 'yy' > "$f2"
  _watch_fingerprint_batch "$f1" "$f2"
  _watch_fingerprint_lookup "$f1"
  local fp1="$_WATCH_PATH_FP"
  _watch_fingerprint_lookup "$f2"
  local fp2="$_WATCH_PATH_FP"
  # Different sizes (1 vs 2 bytes): the size field must actually differ.
  [ "${fp1#* }" = "1" ]
  [ "${fp2#* }" = "2" ]
}

@test "idle-skip: a real fingerprint's mtime is judged to have subsecond precision" {
  local f="$BATS_TEST_TMPDIR/c"
  printf 'x' > "$f"
  _watch_fingerprint_batch "$f"
  _watch_fingerprint_lookup "$f"
  local mt="${_WATCH_PATH_FP%% *}"
  case "$mt" in
    *.0000000\ *|*.000000000) echo "mtime had no fractional precision at all: [$mt]" >&3; skip "this filesystem/stat combination reports no subsecond precision" ;;
  esac
  _watch_mtime_has_subsecond "$mt"
}

@test "idle-skip: an all-zero fraction is judged to lack subsecond precision" {
  refute _watch_mtime_has_subsecond "1793400000.000000000"
}

@test "idle-skip: a bare integer mtime (no fraction at all) is judged to lack subsecond precision" {
  refute _watch_mtime_has_subsecond "1793400000"
}

@test "idle-skip: precision is judged per mtime value, not latched process-wide" {
  # The exact round-3 bug: a fractional reading from one path must not make
  # a DIFFERENT, genuinely coarse value look trustworthy.
  _watch_mtime_has_subsecond "1793400000.123456789"
  refute _watch_mtime_has_subsecond "1793400000.000000000"
}

@test "idle-skip: unsafe-to-arm fires on the WAL's mtime even when the db's own mtime is old" {
  local now; now="$(date +%s)"
  # db: old, integer-second only. wal: "now", integer-second only. The
  # round-3 bug checked only the first field of the fingerprint (the db)
  # and would have armed here.
  _watch_fp_unsafe_to_arm "$now" "100" "$now"
}

@test "idle-skip: unsafe-to-arm does not fire when the only recent mtime has real subsecond precision" {
  local now; now="$(date +%s)"
  refute _watch_fp_unsafe_to_arm "$now" "100" "${now}.5"
}

@test "idle-skip: unsafe-to-arm does not fire when every mtime is well in the past" {
  refute _watch_fp_unsafe_to_arm "$(date +%s)" "1" "2"
}

@test "idle-skip: unsafe-to-arm tolerates an absent (empty) wal mtime" {
  refute _watch_fp_unsafe_to_arm "$(date +%s)" "1" ""
}

@test "idle-skip: a pair fingerprint treats a missing -wal sibling as a known absence, not a failure" {
  local db="$BATS_TEST_TMPDIR/messages.db"
  printf 'x' > "$db"
  _watch_fingerprint_batch "$db"
  _watch_pair_fingerprint "$db" "${db}-wal"
  case "$_WATCH_FP" in
    *'|absent') : ;;
    *) echo "expected a trailing '|absent' for the missing -wal sibling: [$_WATCH_FP]" >&3; false ;;
  esac
}

@test "idle-skip: a pair fingerprint refuses (rc 1) when the db's own stat line never came back" {
  local db="$BATS_TEST_TMPDIR/messages.db"
  printf 'x' > "$db"
  # Batch never asked about $db at all -- the same shape a failed/empty
  # batch leaves behind. The lookup must refuse, not silently treat it as
  # "absent" (the db is known, from the caller's own [ -e ] gate, to exist).
  _watch_fingerprint_batch "$BATS_TEST_TMPDIR/unrelated-file-that-does-not-exist" || true
  refute _watch_pair_fingerprint "$db" "${db}-wal"
}

@test "idle-skip: a wal that exists but never got a stat line also refuses, not 'absent'" {
  local db="$BATS_TEST_TMPDIR/messages.db" wal="$BATS_TEST_TMPDIR/messages.db-wal"
  printf 'x' > "$db"
  printf 'y' > "$wal"
  # Batch only covers $db -- $wal exists on disk but this cycle's batch
  # never asked about it (simulating a stat failure on an existing file:
  # permissions, a race). Must refuse, never silently read as "absent".
  _watch_fingerprint_batch "$db"
  refute _watch_pair_fingerprint "$db" "$wal"
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

