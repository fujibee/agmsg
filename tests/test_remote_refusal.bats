#!/usr/bin/env bats

load test_helper

# A refusal the operator could act on, recorded and readable (#773).
#
# The engine used to treat one as a transport failure: not retryable, so it
# left the loop, and the process exited. `status` then said "engine stopped —
# run: remote.sh sync start", which invites the one action that cannot work.
#
# The reason was never missing — `event()` writes it to the run log — it was
# unread. So what is tested here is the reading: a place `status` opens, and
# the JSON an agent consults, carrying what the server said and nothing this
# client invented.

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem "
    SELECT json_set('$escaped', '\$.remote_binding', json_object(
      'endpoint', 'https://sync.example.test',
      'server_instance_id', '018f0000-0000-7000-8000-000000000001',
      'remote_team_id', '018f0000-0000-7000-8000-000000000002',
      'protocol_version', 1,
      'capabilities', json_object('write_allowed_ciphers', json_array('none')),
      'connected_at', '2026-07-30T00:00:00Z',
      'disconnected_at', null
    ));")"
  printf '%s\n' "$updated" > "$cfg"
  mkdir -p "$TEST_SKILL_DIR/run"
}

teardown() { teardown_test_env; }

# What the engine writes when the server refuses. Written here rather than by
# running the engine: this file is about what READS it.
write_refusal() {
  printf '%s\n' "{\"type\":\"sync_refusal\",\"status\":${1:-402},\"code\":\"${2:-payment_required}\",\"at\":\"2026-08-14T00:00:00Z\",\"endpoint_host\":\"sync.example.test\"}" \
    > "$TEST_SKILL_DIR/run/remote-sync.testteam.refusal.json"
}

@test "status says what the server answered, and does not say what it meant" {
  write_refusal 402 payment_required
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'refused: the server answered 402 payment_required'
  # WHERE the operator of that server is, which the binding already knows.
  printf '%s' "$output" | grep -q 'sync.example.test'
  # And nothing this client invented about what it MEANS. A sentence here
  # would be wrong for some server, and every one of these is a sentence only
  # the operator of that server may write.
  refute grep -qi 'subscri' <<<"$output"
  refute grep -qi 'upgrade' <<<"$output"
  refute grep -qi 'billing' <<<"$output"
  refute grep -qi 'plan' <<<"$output"
}

@test "status repeats a status this protocol never enumerated" {
  # BY CLASS, NOT BY NUMBER. A self-hosted server may refuse for its own
  # reasons with a code nothing here has heard of, and the answer must survive
  # the trip unchanged.
  write_refusal 451 tenant_suspended_by_operator
  run bash "$SCRIPTS/remote.sh" status testteam
  printf '%s' "$output" | grep -q '451 tenant_suspended_by_operator'
}

@test "the agent's surface carries it, verbatim" {
  # `/agmsg remote status` runs this. It is the only thing an agent consults
  # about the engine, so a refusal that reached only the human line would
  # leave "why isn't this syncing?" unanswerable.
  write_refusal 402 payment_required
  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  local got
  got="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["refusal"]["status"])')"
  [ "$got" = "402" ]
  got="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["refusal"]["code"])')"
  [ "$got" = "payment_required" ]
  got="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["refusal"]["endpoint_host"])')"
  [ "$got" = "sync.example.test" ]
}

@test "no refusal is null, not a missing key" {
  # A consumer that has to tell "absent" from "unreadable" needs the key to be
  # there either way.
  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  local got
  got="$(printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("KEY" if "refusal" in d else "MISSING", d["refusal"])')"
  [ "$got" = "KEY None" ]
}

@test "an unreadable record reads as absent, not as a guess" {
  printf '%s\n' 'not json at all' > "$TEST_SKILL_DIR/run/remote-sync.testteam.refusal.json"
  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  local got
  got="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["refusal"])')"
  [ "$got" = "None" ]
}

@test "the engine carries no knowledge of any particular remote" {
  # The requirement that is easiest to lose later, so it is a check rather
  # than a note. `402` is the case that exists today and the engine classifies
  # by CLASS — a 4xx the retry policy does not cover — so the number has no
  # business being in there.
  refute grep -n '402' "$SCRIPTS/internal/remote-sync.mjs"
  refute grep -ni 'payment_required' "$SCRIPTS/internal/remote-sync.mjs"
  # A positive control on the search itself: it has to be able to find
  # something in that file, or these three prove nothing.
  grep -q 'isRefusal' "$SCRIPTS/internal/remote-sync.mjs"
}

# ── a refusal that is no longer true ────────────────────────────────────────
#
# The engine removes the record after a successful cycle, best-effort. If that
# removal fails — an unwritable run directory, a permission change, a crash
# between the two writes — the file stays. Nothing else stood between it and
# the operator, so `status` reported a reversed decision for ever (raised in
# review, and it contradicted this PR's own stated standard).
#
# The reader now compares the record to the last successful cycle. Deleting can
# fail; comparing cannot.

write_cycle_stamp() {
  printf '%s\n' "{\"type\":\"sync_cycle_stamp\",\"first_success_at\":\"$1\",\"last_success_at\":\"$1\"}" \
    > "$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json"
}

@test "a refusal older than the last successful cycle is not reported, even if the file remains" {
  write_refusal 402 payment_required                # recorded at 2026-08-14T00:00:00Z
  write_cycle_stamp "2026-08-14T01:00:00Z"          # and a cycle succeeded after it
  # The file is still there — this is the failed-delete case, made deliberate.
  [ -f "$TEST_SKILL_DIR/run/remote-sync.testteam.refusal.json" ]

  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  refute grep -q 'refused:' <<<"$output"

  run bash "$SCRIPTS/remote.sh" status testteam --json
  local got
  got="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["refusal"])')"
  [ "$got" = "None" ]
}

@test "a refusal newer than the last successful cycle is still reported" {
  # The other side of the comparison. Without this the check could be satisfied
  # by never reporting anything, which is the failure mode of every filter.
  write_cycle_stamp "2026-08-13T00:00:00Z"
  write_refusal 402 payment_required                # recorded a day later
  run bash "$SCRIPTS/remote.sh" status testteam
  printf '%s' "$output" | grep -q 'refused: the server answered 402'

  run bash "$SCRIPTS/remote.sh" status testteam --json
  local got
  got="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["refusal"]["status"])')"
  [ "$got" = "402" ]
}

@test "with no cycle stamp at all, the refusal is reported" {
  # An engine that has refused and never succeeded is exactly the case the
  # record exists for. Nothing to compare against must not mean "assume stale".
  write_refusal 402 payment_required
  [ ! -f "$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json" ]
  run bash "$SCRIPTS/remote.sh" status testteam
  printf '%s' "$output" | grep -q 'refused: the server answered 402'
}

# What the engine writes to the run log when its main loop throws uncaught
# (remote-sync.mjs's `event("fatal", ...)`) -- a LOCAL failure (a missing
# `age` binary, say) as much as a server-side one, unlike write_refusal above
# which only ever models a 4xx the server sent. Written here rather than by
# running the engine, for the same reason write_refusal is: this is about what
# READS it (#1487).
write_fatal() {
  printf '{"at":"2026-08-14T00:00:00Z","event":"fatal","message":"%s"}\n' "$1" \
    >> "$TEST_SKILL_DIR/run/remote-sync.testteam.log"
}

@test "status names the engine's own last fatal reason while it is not running" {
  # Before #1487, an engine that died at its first push (e.g. a missing `age`)
  # read as merely "engine stopped" -- true, but silent about why, with the
  # reason sitting unread in this same log.
  write_fatal 'age executable not found on PATH'
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'engine stopped'
  printf '%s' "$output" | grep -q 'last fatal: age executable not found on PATH'
}

# What `_remote_sync_engine_start_locked` writes as the very first thing
# every start does, before the engine process even exists -- unlike
# `capabilities`, which only appears once a run has reached the server, and
# so never appears at all for a run killed before that (review round 2).
write_engine_start() {
  printf '{"at":"2026-08-14T00:05:00Z","event":"engine.start","startup_nonce":"test-nonce"}\n' \
    >> "$TEST_SKILL_DIR/run/remote-sync.testteam.log"
}

@test "an old fatal from before the engine restarted is not reported as current" {
  # This team failed once (write_fatal), was restarted (write_engine_start --
  # the log is append-only across restarts, `>> "$logfile"` at every start),
  # and that later run stopped normally -- WITHOUT ever writing `capabilities`
  # or a `fatal` of its own (e.g. a plain SIGTERM during startup, before it
  # reached the server). The FIRST run's fatal must not be attributed to why
  # the team is stopped now, and `engine.start` is the boundary this survives
  # on even though this later run logged nothing else at all (#1487 review
  # round 2 -- `capabilities` alone left exactly this case unguarded).
  write_fatal 'age executable not found on PATH'
  write_engine_start
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'engine stopped'
  refute grep -q 'last fatal' <<<"$output"
}
