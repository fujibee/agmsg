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

@test "partition cache: a transient read failure never poisons a later recovery (review round 1/2)" {
  bash "$SCRIPTS/join.sh" flakyteam alice claude-code "$BATS_TEST_TMPDIR/proj4" >/dev/null
  _set_partition flakyteam per-team
  local cfg="$TEST_SKILL_DIR/teams/flakyteam/config.json"

  # The read failure has to land on the VERY FIRST resolution (a cache
  # MISS) -- chmod'ing an ALREADY-cached, unchanged file is a no-op as far
  # as this cache is concerned (review round 2's own finding: `stat`
  # succeeds either way, so an unchanged fingerprint is correctly a cache
  # HIT regardless of current readability -- that case needs no read at
  # all and is not a bug). `stat` itself does not need read permission on
  # the file, only search permission on its parent directories (confirmed
  # directly), so this simulates exactly that: metadata is fine, content
  # is not, on a resolution that has nothing cached yet.
  chmod 000 "$cfg"
  _agmsg_partition_load flakyteam
  chmod 644 "$cfg"
  [ "$_AGMSG_PARTITION_LOADED" = shared ] || skip "this environment could read a chmod 000 file; the failure this test needs did not occur"

  # Recovery: content is readable again, and -- because the file was NEVER
  # actually rewritten -- its fingerprint is back to exactly what it was
  # during the failure. The pre-fix bug: that match hit a cache entry the
  # failure itself had left behind, reusing "shared" forever instead of
  # ever deriving the real "per-team".
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
  local sub="${out#*$'\t'}"; sub="${sub%%$'\t'*}"
  [ "$sub" = 0 ]
}

@test "partition cache: an all-zero fraction next to a non-zero SIZE is still judged coarse (review round 3)" {
  source "$SCRIPTS/lib/compat.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/driver-registry.sh"
  local shim="$BATS_TEST_TMPDIR/shim4"
  mkdir -p "$shim"
  # A coarse mtime (".000000000") paired with an ORDINARY, non-zero file
  # size -- the exact shape that made an earlier version's whole-string
  # match ("*.*[1-9]*" against "<mtime> <size>") wrongly see the SIZE's
  # own digits as subsecond precision in the MTIME.
  printf '#!/usr/bin/env bash\necho "1793480000.000000000 42"\n' > "$shim/stat"
  chmod +x "$shim/stat"
  mkdir -p "$TEST_SKILL_DIR/teams/coarsesizeteam"
  printf '{"drivers":{"partition":"shared"}}' > "$TEST_SKILL_DIR/teams/coarsesizeteam/config.json"
  local out
  out="$(PATH="$shim:$PATH" _agmsg_partition_cfg_fingerprint coarsesizeteam)"
  local sub="${out#*$'\t'}"
  [ "$sub" = 0 ]
}

@test "partition cache: a readable config whose sqlite lookup fails recovers on the next cycle, not poisoned (review round 4)" {
  bash "$SCRIPTS/join.sh" sqlfailteam alice claude-code "$BATS_TEST_TMPDIR/proj6" >/dev/null
  _set_partition sqlfailteam per-team

  local real_sqlite3="$(command -v sqlite3)"
  local shim="$BATS_TEST_TMPDIR/shim5"
  mkdir -p "$shim"
  # Simulate a decisive, confirmable SQL lookup failure (not a permission
  # issue -- the content is perfectly readable) on the team's FIRST-EVER
  # resolution: the shim exits non-zero while a marker file exists, exactly
  # as a transient sqlite3 failure (resource limits, a locked :memory:
  # handle, etc.) would. Removing the marker lets the SECOND call
  # (recovery) go through to the real binary.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ -e %q ]; then exit 1; fi\n' "$BATS_TEST_TMPDIR/fail-once"
    printf 'exec %q "$@"\n' "$real_sqlite3"
  } > "$shim/sqlite3"
  chmod +x "$shim/sqlite3"
  : > "$BATS_TEST_TMPDIR/fail-once"

  PATH="$shim:$PATH" _agmsg_partition_load sqlfailteam
  [ "$_AGMSG_PARTITION_LOADED" = shared ] || skip "the sqlite3 shim's failure was not exercised as expected"

  rm -f "$BATS_TEST_TMPDIR/fail-once"
  _AGMSG_POLL_CYCLE_EPOCH=$((_AGMSG_POLL_CYCLE_EPOCH + 1))
  PATH="$shim:$PATH" _agmsg_partition_load sqlfailteam
  [ "$_AGMSG_PARTITION_LOADED" = per-team ]
}

@test "partition cache: malformed JSON is never confused with a legitimate default (review round 4)" {
  mkdir -p "$TEST_SKILL_DIR/teams/malformedteam"
  printf 'not valid json{{{' > "$TEST_SKILL_DIR/teams/malformedteam/config.json"
  source "$SCRIPTS/lib/compat.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/driver-registry.sh"
  agmsg_driver_for_team_confirmed partition malformedteam shared
  [ "$_AGMSG_DRIVER_RESOLVED_NAME" = shared ]
  [ "$_AGMSG_DRIVER_CONFIRMED" = 0 ]
}

@test "partition cache: a team with no drivers key at all is a CONFIRMED legitimate default" {
  mkdir -p "$TEST_SKILL_DIR/teams/nodriverskeyteam"
  printf '{"other":1}' > "$TEST_SKILL_DIR/teams/nodriverskeyteam/config.json"
  source "$SCRIPTS/lib/compat.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/driver-registry.sh"
  agmsg_driver_for_team_confirmed partition nodriverskeyteam shared
  [ "$_AGMSG_DRIVER_RESOLVED_NAME" = shared ]
  [ "$_AGMSG_DRIVER_CONFIRMED" = 1 ]
}
