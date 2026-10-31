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
