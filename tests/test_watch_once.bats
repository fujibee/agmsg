#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="/tmp/agmsg-watch-once-proj"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

# --- lifetime bound vs slow startup (#558) -----------------------------------
#
# The bridge force-kills this child at (timeout + interval + 10) seconds from
# spawn, so the deadline has to bound the whole process, not just the polling.
# The bug these pin is a deadline computed AFTER startup, which makes the real
# wall time startup + TIMEOUT and produces exit 124 on hosts where startup is
# slow (Windows/MSYS fork emulation, ~29s measured).
#
# Startup here is ~0.2s, so the difference is invisible unless startup is made
# slow deliberately. `_slow_startup_path` does that with an `awk` shim: startup
# resolves subscription pairs through awk, while the polling loop queries through
# sqlite3, so delaying awk lengthens startup without touching the poll. The shim
# sleeps once (marker file) so the delay is exactly N regardless of how many awk
# calls startup makes.
_slow_startup_path() {
  local secs="$1" dir="$BATS_TEST_TMPDIR/slowbin"
  mkdir -p "$dir"
  cat > "$dir/awk" <<EOF
#!/usr/bin/env bash
if [ ! -e "$BATS_TEST_TMPDIR/awk-delayed" ]; then
  : > "$BATS_TEST_TMPDIR/awk-delayed"
  sleep $secs
fi
exec $(command -v awk) "\$@"
EOF
  chmod +x "$dir/awk"
  printf '%s' "$dir"
}

# The shim IS the premise: without the delay, an unfixed watch-once finishes in
# about TIMEOUT and satisfies the ceiling, so the test would go green against the
# very bug it exists for. Requiring the marker turns "startup no longer routes
# through awk" into a loud failure instead of a silent pass.
_assert_startup_was_delayed() {
  [ -e "$BATS_TEST_TMPDIR/awk-delayed" ] || {
    echo "the awk shim never fired — startup no longer routes through awk, so this test proves nothing; re-pick the seam"
    false
  }
}

@test "watch-once: total lifetime stays within the timeout even when startup is slow (#558)" {
  local bin start end elapsed
  bin="$(_slow_startup_path 3)"

  start=$(date +%s)
  PATH="$bin:$PATH" run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex \
    --name alice --team team --timeout 4 --interval 1
  end=$(date +%s)
  elapsed=$(( end - start ))

  [ "$status" -eq 2 ]
  _assert_startup_was_delayed
  # The contract is the ceiling, not a precise duration: with the deadline taken
  # after startup this runs ~3+4=7s, so a 6s bound separates the two without
  # being tight enough to flake on a loaded runner.
  [ "$elapsed" -le 6 ] || { echo "lifetime ${elapsed}s exceeded the 4s timeout by more than slack"; false; }
}

@test "watch-once: a deadline already past still performs one inbox check (#558)" {
  # Startup longer than the whole timeout, so the deadline is in the past by the
  # time the loop starts. The pending message must still be found: the fix must
  # bound the lifetime, not skip the work.
  bash "$SCRIPTS/send.sh" team bob alice "pending despite slow startup" >/dev/null
  local bin
  bin="$(_slow_startup_path 3)"

  PATH="$bin:$PATH" run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex \
    --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 0 ]
  _assert_startup_was_delayed
  [[ "$output" =~ "status=pending" ]]
}

@test "watch-once: exits 2 on timeout when no unread inbound exists" {
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=timeout" ]]
}

@test "watch-once: reports existing unread inbound without marking it read" {
  bash "$SCRIPTS/send.sh" team bob alice "hello pending" >/dev/null

  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=pending" ]]
  [[ "$output" =~ "count=1" ]]

  run bash "$SCRIPTS/inbox.sh" team alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello pending" ]]
}

@test "watch-once: ignores messages already read by inbox.sh" {
  bash "$SCRIPTS/send.sh" team bob alice "read already" >/dev/null
  bash "$SCRIPTS/inbox.sh" team alice >/dev/null

  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=timeout" ]]
}

@test "watch-once: ignores messages addressed to another agent" {
  bash "$SCRIPTS/send.sh" team alice bob "for bob" >/dev/null

  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=timeout" ]]
}

@test "watch-once: detects a message that arrives after it starts" {
  bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 5 --interval 1 \
    >"$TEST_SKILL_DIR/watch-once.out" 2>"$TEST_SKILL_DIR/watch-once.err" 3>&- &
  local pid=$!
  sleep 1
  bash "$SCRIPTS/send.sh" team bob alice "arrived later" >/dev/null
  wait "$pid"
  local status=$?

  [ "$status" -eq 0 ]
  grep -q "status=pending" "$TEST_SKILL_DIR/watch-once.out"
}

@test "watch-once: skips a subscription held by another live session" {
  setup_live_owner "$TEST_SKILL_DIR/run" other-sid
  bash "$SCRIPTS/actas-claim.sh" "$PROJ" codex alice other-sid >/dev/null
  bash "$SCRIPTS/send.sh" team bob alice "locked out" >/dev/null

  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 1 ]
  [[ "$output" =~ "no available subscription" ]]
}

# --- #605: when the exclusion above empties the whole subscription, name the
#     lock file and whether cc-instance.<pid> backs the owner. A composite
#     owner with no matching cc-instance file is instance-id.sh's
#     unconditional-alive branch -- the one worth being able to spot. ------
@test "watch-once: #605 names the lock path and reports cc-instance as absent" {
  local lock="$TEST_SKILL_DIR/run/actas.team__alice.session"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadbeef-thread.$$" > "$lock"
  bash "$SCRIPTS/send.sh" team bob alice "locked out" >/dev/null

  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"lock=$lock"* ]]
  [[ "$output" == *"cc-instance=absent"* ]]
}

@test "watch-once: #605 facts stay quiet when another pair still resolves" {
  setup_live_owner "$TEST_SKILL_DIR/run" other-sid
  bash "$SCRIPTS/actas-claim.sh" "$PROJ" codex alice other-sid >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob "for bob, not alice" >/dev/null

  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --team team --timeout 1 --interval 1
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=pending" ]]
  [[ "$output" != *"lock="* ]]
}
