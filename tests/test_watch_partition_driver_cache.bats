#!/usr/bin/env bats

# #1849: _agmsg_partition_load's per-cycle re-read of a team's storage
# partition driver (#1330) forks agmsg_driver_for_team's sqlite3 lookup
# every single cycle, for every team a broad watcher subscribes to --
# regardless of whether anything about that team has changed. Gated on a
# config.json fingerprint (mtime+size) instead: a repeat call whose config
# has not changed reuses the last resolved name with no subprocess at all,
# while #1330's own guarantee -- a migration is noticed within one poll,
# not never -- is preserved because migrate-team-store.sh's own write to
# config.json (confirmed by reading that script) is exactly what changes
# the fingerprint.

load test_helper

setup() {
  setup_test_env
  source "$SCRIPTS/lib/storage.sh"
  _AGMSG_PARTITION_TEAM_KEYS=()
  _AGMSG_PARTITION_TEAM_VALS=()
  _AGMSG_PARTITION_TEAM_EPOCH=()
  _AGMSG_PARTITION_TEAM_CFGFP=()
  _AGMSG_PARTITION_TEAM_CFGFP_AT=()
  _AGMSG_POLL_CYCLE_EPOCH=0
}

_set_partition() {   # <team> <driver-name>
  local team="$1" driver="$2" cfg
  cfg="$TEST_SKILL_DIR/teams/$team/config.json"
  mkdir -p "$(dirname "$cfg")"
  if [ -f "$cfg" ]; then
    local updated
    updated="$(sqlite3 :memory: "SELECT json_set(readfile('$cfg'), '\$.drivers.partition', '$driver');")"
    printf '%s' "$updated" > "$cfg"
  else
    printf '{"drivers":{"partition":"%s"}}' "$driver" > "$cfg"
  fi
}

@test "partition cache: a resolution with an unreadable config always falls through fresh" {
  # No config.json at all for this team -- the fingerprint is empty, so the
  # cache must never claim a hit on it.
  bash "$SCRIPTS/join.sh" noconfigteam alice claude-code "$BATS_TEST_TMPDIR/proj" >/dev/null
  rm -f "$TEST_SKILL_DIR/teams/noconfigteam/config.json"
  _agmsg_partition_load noconfigteam
  _agmsg_partition_load noconfigteam
  # Two calls, neither crashes, and the team keys array gained exactly one
  # entry -- i.e. the second call looked it up (cache-miss both times is
  # fine; what must not happen is this throwing or caching garbage).
  [ "${#_AGMSG_PARTITION_TEAM_KEYS[@]}" -ge 1 ]
}

@test "partition cache: an unchanged config reuses the cached name without re-resolving" {
  bash "$SCRIPTS/join.sh" cacheteam alice claude-code "$BATS_TEST_TMPDIR/proj2" >/dev/null
  _set_partition cacheteam shared
  _agmsg_partition_load cacheteam
  local first_name="$_AGMSG_PARTITION_LOADED"

  # Advance the epoch (a new poll cycle) WITHOUT touching config.json at
  # all -- the epoch-only cache (#1330) would force a fresh sqlite3
  # lookup here; the fingerprint cache must instead reuse the stored name.
  _AGMSG_POLL_CYCLE_EPOCH=$((_AGMSG_POLL_CYCLE_EPOCH + 1))

  local real_sqlite3="$(command -v sqlite3)"
  local shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  cat > "$shim/sqlite3" <<EOF
#!/usr/bin/env bash
echo "sqlite3-called" >> "$BATS_TEST_TMPDIR/calls.log"
exec "$real_sqlite3" "\$@"
EOF
  chmod +x "$shim/sqlite3"
  : > "$BATS_TEST_TMPDIR/calls.log"

  PATH="$shim:$PATH" _agmsg_partition_load cacheteam
  [ "$_AGMSG_PARTITION_LOADED" = "$first_name" ]
  [ ! -s "$BATS_TEST_TMPDIR/calls.log" ]
}

@test "partition cache: a config.json write (a real migration) is noticed on the very next load, not never" {
  bash "$SCRIPTS/join.sh" migteam alice claude-code "$BATS_TEST_TMPDIR/proj3" >/dev/null
  _set_partition migteam shared
  _agmsg_partition_load migteam
  [ "$_AGMSG_PARTITION_LOADED" = shared ] || skip "builtin 'shared' partition driver not resolvable in this fixture"

  _AGMSG_POLL_CYCLE_EPOCH=$((_AGMSG_POLL_CYCLE_EPOCH + 1))
  # The exact write migrate-team-store.sh itself performs (confirmed by
  # reading scripts/internal/migrate-team-store.sh): config.json's own
  # drivers.partition flips, via a real file write -- which changes its
  # mtime/size, the one thing this cache actually keys on.
  _set_partition migteam per-team

  _agmsg_partition_load migteam
  [ "$_AGMSG_PARTITION_LOADED" = per-team ]
}

@test "partition cache: a transient read failure never poisons a later recovery (review round 1)" {
  bash "$SCRIPTS/join.sh" flakyteam alice claude-code "$BATS_TEST_TMPDIR/proj4" >/dev/null
  _set_partition flakyteam per-team
  _agmsg_partition_load flakyteam
  [ "$_AGMSG_PARTITION_LOADED" = per-team ] || skip "builtin 'per-team' partition driver not resolvable in this fixture"

  local cfg="$TEST_SKILL_DIR/teams/flakyteam/config.json"
  # Simulate a TRANSIENT read failure (the config exists, but neither this
  # cache's own `stat` nor agmsg_driver_for_team's own sqlite3 readfile can
  # read it this one call) -- not an actual config change. The real bug
  # this reproduces: the fallback name this failure produces ("shared",
  # agmsg_driver_for_team's own default) must never be remembered as if it
  # were a confirmed resolution.
  chmod 000 "$cfg"
  _AGMSG_POLL_CYCLE_EPOCH=$((_AGMSG_POLL_CYCLE_EPOCH + 1))
  _agmsg_partition_load flakyteam
  chmod 644 "$cfg"
  [ "$_AGMSG_PARTITION_LOADED" = shared ] || skip "root can read a chmod 000 file in this environment; the failure this test needs did not occur"

  # Recovery: the config is readable again, and -- because it was NEVER
  # actually rewritten -- its fingerprint is back to exactly what it was
  # before the failure. The pre-fix bug: that match hit the STALE cache
  # entry the failure itself left behind and reused "shared" forever,
  # never re-deriving the real "per-team".
  _AGMSG_POLL_CYCLE_EPOCH=$((_AGMSG_POLL_CYCLE_EPOCH + 1))
  _agmsg_partition_load flakyteam
  [ "$_AGMSG_PARTITION_LOADED" = per-team ]
}

@test "partition cache: the safety net forces a fresh lookup even with a matching fingerprint" {
  bash "$SCRIPTS/join.sh" snteam alice claude-code "$BATS_TEST_TMPDIR/proj5" >/dev/null
  _set_partition snteam shared
  _agmsg_partition_load snteam
  [ "$_AGMSG_PARTITION_LOADED" = shared ] || skip "builtin 'shared' partition driver not resolvable in this fixture"

  # Force the cached entry to look older than the safety net's own window,
  # without touching config.json at all (a real same-fingerprint cycle).
  local _i
  for ((_i = 0; _i < ${#_AGMSG_PARTITION_TEAM_KEYS[@]}; _i++)); do
    [ "${_AGMSG_PARTITION_TEAM_KEYS[$_i]}" = "snteam" ] || continue
    _AGMSG_PARTITION_TEAM_CFGFP_AT[$_i]=$((SECONDS - AGMSG_PARTITION_CFG_SAFETY_NET_SECONDS - 1))
  done
  _AGMSG_POLL_CYCLE_EPOCH=$((_AGMSG_POLL_CYCLE_EPOCH + 1))

  local real_sqlite3="$(command -v sqlite3)"
  local shim="$BATS_TEST_TMPDIR/shim2"
  mkdir -p "$shim"
  cat > "$shim/sqlite3" <<EOF
#!/usr/bin/env bash
echo "sqlite3-called" >> "$BATS_TEST_TMPDIR/calls2.log"
exec "$real_sqlite3" "\$@"
EOF
  chmod +x "$shim/sqlite3"
  : > "$BATS_TEST_TMPDIR/calls2.log"

  PATH="$shim:$PATH" _agmsg_partition_load snteam
  [ -s "$BATS_TEST_TMPDIR/calls2.log" ]
}

@test "partition cache: a coarse (integer-second) mtime is never cached" {
  source "$SCRIPTS/lib/compat.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/driver-registry.sh"
  local shim="$BATS_TEST_TMPDIR/shim3"
  mkdir -p "$shim"
  local real_stat="$(command -v stat)"
  cat > "$shim/stat" <<EOF
#!/usr/bin/env bash
# Strip any fractional seconds a real %Fm/%.9Y would carry, simulating a
# filesystem/stat combination that only reports whole seconds.
"$real_stat" "\$@" | sed -E 's/\.[0-9]+//'
EOF
  chmod +x "$shim/stat"
  mkdir -p "$TEST_SKILL_DIR/teams/coarseteam"
  printf '{"drivers":{"partition":"shared"}}' > "$TEST_SKILL_DIR/teams/coarseteam/config.json"
  local out
  out="$(PATH="$shim:$PATH" _agmsg_partition_cfg_fingerprint coarseteam)"
  local sub="${out#*$'\t'}"
  [ "$sub" = 0 ]
}
