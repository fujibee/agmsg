#!/usr/bin/env bats

# Unit tests for the watcher's stuck-cursor tracker (lib/watch-stuck-map.sh,
# #1045 fix 2). These exercise the two failure modes a full-watcher test cannot
# pin down deterministically on a shared host, where a poll-cycle count drifts
# with load (see [[this machine cannot measure time]]):
#
#   1. A team or agent NAME WITH A SPACE must still be tracked. The first cut
#      framed records with a space and scanned them with `for e in $MAP`, so a
#      spaced name split across two words and its record never matched -- the
#      guard then never fired for that pair. Restoring word splitting turns the
#      "spaced name round-trips" tests below RED.
#   2. The count must RESET when the watcher stops observing a pair (held by
#      another session, or no store yet). Those branches call _stuck_drop; if
#      they did not, a resumed pair would inherit its old count and a healthy
#      watcher would exit early. "a drop makes a resumed pair start fresh" is
#      that reset, isolated from timing.

load test_helper

setup() {
  setup_test_env
  source "$SCRIPTS/lib/watch-stuck-map.sh"
  STUCK_MAP=""
}

# Read _stuck_get "$1" into globals GC (cursor) and GN (count); empty when absent.
_get() {
  local raw; raw="$(_stuck_get "$1")"
  IFS=$'\x1f' read -r GC GN <<< "$raw"
}

@test "stuck-map: a pair with spaces in both team and agent round-trips" {
  local P="team a:agent x"
  _stuck_set "$P" 100 1
  _get "$P"
  [ "$GC" = "100" ]
  [ "$GN" = "1" ]
}

@test "stuck-map: a spaced pair reaches a bumped count (the guard can fire for it)" {
  local P="team a:agent x"
  _stuck_set "$P" 100 1
  _stuck_set "$P" 100 2
  _stuck_set "$P" 100 3
  _get "$P"
  [ "$GC" = "100" ]
  [ "$GN" = "3" ]
}

@test "stuck-map: setting a pair replaces its record, it is never duplicated" {
  local P="team a:agent x"
  _stuck_set "$P" 100 1
  _stuck_set "$P" 100 2
  # Exactly one record for the pair -> exactly one line in the map.
  [ "$(printf '%s\n' "$STUCK_MAP" | grep -c .)" -eq 1 ]
  _get "$P"
  [ "$GN" = "2" ]
}

@test "stuck-map: two pairs are independent; dropping one keeps the other" {
  local P="team a:agent x" Q="team:bob"
  _stuck_set "$P" 100 2
  _stuck_set "$Q" 200 1
  _stuck_drop "$P"
  _get "$P"
  [ -z "$GC" ] && [ -z "$GN" ]
  _get "$Q"
  [ "$GC" = "200" ]
  [ "$GN" = "1" ]
}

@test "stuck-map: a drop makes a resumed pair start fresh, not inherit its count" {
  # Model the held/no-store gap: a pair builds a count, the watcher stops
  # observing it (drop), then serves it again. On resume _stuck_get returns
  # empty, so the caller starts the count at 1 -- not at old+1, which for a
  # count already at threshold-1 would exit a healthy watcher on the first
  # cycle back. Without the drop on those branches this is old+1.
  local P="team a:agent x"
  _stuck_set "$P" 100 2        # two consecutive stuck cycles observed
  _stuck_drop "$P"             # held elsewhere / store gone for a cycle
  _get "$P"                    # resumed: nothing remembered
  [ -z "$GN" ]
}

@test "stuck-map: one pair is not matched by another that shares a prefix" {
  local A="team:al" B="team:alice"
  _stuck_set "$A" 100 1
  _stuck_set "$B" 200 2
  _get "$A"; [ "$GC" = "100" ] && [ "$GN" = "1" ]
  _get "$B"; [ "$GC" = "200" ] && [ "$GN" = "2" ]
  _stuck_drop "$A"
  _get "$A"; [ -z "$GN" ]
  _get "$B"; [ "$GN" = "2" ]   # dropping "team:al" must not touch "team:alice"
}

@test "stuck-map: dropping an untracked pair is a no-op on an empty and a full map" {
  _stuck_drop "team:nobody"    # empty map
  [ -z "$STUCK_MAP" ]
  _stuck_set "team:bob" 200 1
  _stuck_drop "team:nobody"    # full map, pair absent
  _get "team:bob"; [ "$GN" = "1" ]
}

# --- _pair_gate: the drop is TIED to the skip decision (finding 2, round 3) ---
# These pin the property AT the two skip entries, which a helper-only reset test
# could not: the earlier code dropped the tracker in a separate statement at each
# `continue`, so deleting it left every test green. Now the drop is inside the
# gate's skip verdict, and these seed a count at threshold-1, fire each skip
# transition, and assert the production state was removed -- no wall clock.

@test "pair-gate: held-by-another drops the pair's stuck count and says skip" {
  storage_store_exists() { return 0; }        # not consulted on the held path
  _stuck_set "team:alice" 42 2                 # seed threshold-1
  _pair_gate team alice "other:sess9"
  [ "$PAIR_VERDICT" = "held:sess9" ]
  _get "team:alice"; [ -z "$GN" ]              # the count was forgotten
}

@test "pair-gate: no-store drops the pair's stuck count and says skip" {
  storage_store_exists() { return 1; }         # store absent
  _stuck_set "team:alice" 42 2                 # seed threshold-1
  _pair_gate team alice "free"
  [ "$PAIR_VERDICT" = "nostore" ]
  _get "team:alice"; [ -z "$GN" ]              # the count was forgotten
}

@test "pair-gate: a servable pair keeps its count (a success is not a skip)" {
  storage_store_exists() { return 0; }         # store present
  _stuck_set "team:alice" 42 2                 # seed threshold-1
  _pair_gate team alice "free"
  [ "$PAIR_VERDICT" = "serve" ]
  _get "team:alice"; [ "$GC" = "42" ] && [ "$GN" = "2" ]   # untouched -> guard can still fire
}

@test "pair-gate: skip drops only the gated pair, not another tracked pair" {
  storage_store_exists() { return 1; }
  _stuck_set "team:alice" 42 2
  _stuck_set "team:bob" 99 2
  _pair_gate team alice "free"                  # no-store skip for alice
  _get "team:alice"; [ -z "$GN" ]
  _get "team:bob"; [ "$GC" = "99" ] && [ "$GN" = "2" ]
}
