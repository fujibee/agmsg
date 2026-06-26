#!/usr/bin/env bats

# Tests for the per-process instance id (#93): parallel claude --continue /
# --resume processes share a session_id, so watcher/lock state keyed on the
# bare session_id collides. instance-id.sh disambiguates with the enclosing
# agent pid. These cover the helper functions and the actas-lock distinctness
# the fix turns on.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/resolve-project.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/instance-id.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
}

teardown() { teardown_test_env; }

# --- agmsg_instance_id_from_pid ---

@test "instance_id_from_pid: numeric pid yields composite" {
  [ "$(agmsg_instance_id_from_pid sess 1234)" = "sess.1234" ]
}

@test "instance_id_from_pid: empty pid yields bare sid" {
  [ "$(agmsg_instance_id_from_pid sess "")" = "sess" ]
}

@test "instance_id_from_pid: non-numeric pid yields bare sid" {
  [ "$(agmsg_instance_id_from_pid sess abc)" = "sess" ]
}

# --- agmsg_instance_is_composite ---

@test "is_composite: true for <sid>.<numeric>" {
  agmsg_instance_is_composite "sess.1234"
}

@test "is_composite: true for a UUID-shaped sid with numeric suffix" {
  agmsg_instance_is_composite "11111111-2222-3333-4444-555555555555.987"
}

@test "is_composite: false for a bare sid" {
  ! agmsg_instance_is_composite "sess"
}

@test "is_composite: false for empty suffix" {
  ! agmsg_instance_is_composite "sess."
}

@test "is_composite: false for empty prefix" {
  ! agmsg_instance_is_composite ".1234"
}

@test "is_composite: false for non-numeric suffix" {
  ! agmsg_instance_is_composite "sess.12a"
}

# --- agmsg_instance_alive ---

@test "instance_alive: composite with a live pid is alive" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  agmsg_instance_alive "sess.$$"
}

@test "instance_alive: composite with a dead pid is not alive" {
  ! agmsg_instance_alive "sess.2147483647"
}

@test "instance_alive: bare sid with a live cc-instance is alive" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  echo "barex" > "$RUN_DIR/cc-instance.$$"
  agmsg_instance_alive "barex"
}

@test "instance_alive: bare sid is alive when cc-instance was upgraded to composite (compat)" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  # A pre-upgrade lock holds a bare sid while cc-instance already stores the
  # composite "<sid>.<pid>" — must not be stale'd out.
  echo "barey.$$" > "$RUN_DIR/cc-instance.$$"
  agmsg_instance_alive "barey"
}

@test "instance_alive: bare sid with no cc-instance is not alive" {
  ! agmsg_instance_alive "ghost"
}

@test "instance_alive: empty token is not alive" {
  ! agmsg_instance_alive ""
}

# --- agmsg_normalize_instance_id ---

@test "normalize: a composite token passes through unchanged (idempotent)" {
  [ "$(agmsg_normalize_instance_id "sess.4242" claude-code 2>/dev/null)" = "sess.4242" ]
}

@test "normalize: a bare sid derives the composite from the agent pid" {
  # Stub the resolver so the derivation is deterministic without a real agent
  # ancestor (bats has none).
  agmsg_agent_pid() { echo 4242; }
  [ "$(agmsg_normalize_instance_id "sess" claude-code)" = "sess.4242" ]
}

@test "normalize: falls back to the bare sid when the agent pid is unresolved" {
  agmsg_agent_pid() { return 1; }
  # Capture stdout only — the fallback also writes a warning to stderr.
  local got
  got="$(agmsg_normalize_instance_id "sess" claude-code 2>/dev/null)"
  [ "$got" = "sess" ]
}

@test "normalize: warns on stderr when falling back" {
  agmsg_agent_pid() { return 1; }
  run bash -c '
    source "'"$SKILL_DIR"'/scripts/lib/resolve-project.sh"
    source "'"$SKILL_DIR"'/scripts/lib/instance-id.sh"
    agmsg_agent_pid() { return 1; }
    agmsg_normalize_instance_id sess claude-code 2>&1 1>/dev/null
  '
  [[ "$output" == *"falling back to bare session_id"* ]]
}

# --- AGMSG_AGENT_PID override ---

@test "override: a numeric AGMSG_AGENT_PID pins the resolved pid" {
  AGMSG_AGENT_PID=4242 run agmsg_agent_pid claude-code
  [ "$status" -eq 0 ]
  [ "$output" = "4242" ]
  [ "$(AGMSG_AGENT_PID=4242 agmsg_instance_id sess claude-code)" = "sess.4242" ]
}

@test "override: an empty AGMSG_AGENT_PID forces the bare fallback" {
  AGMSG_AGENT_PID="" run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "$(AGMSG_AGENT_PID="" agmsg_instance_id sess claude-code 2>/dev/null)" = "sess" ]
}

@test "override: a non-numeric AGMSG_AGENT_PID is ignored with a warning" {
  AGMSG_AGENT_PID="abc" run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]
  [[ "$output" == *"ignoring non-numeric AGMSG_AGENT_PID"* ]]
}

# --- actas distinctness: the #93 payoff ---

# Two instance ids that share a session_id prefix but differ in pid must be
# treated as distinct owners — the collision that broke the actas lock is gone.
@test "actas: same session_id, different pid -> distinct live owners (#93)" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  sleep 60 & local pa=$!
  sleep 60 & local pb=$!
  local ta="sess.$pa" tb="sess.$pb"

  # pa claims; pb is refused because pa is a live, distinct owner.
  run actas_lock_claim team alice "$ta"
  [ "$status" -eq 0 ]
  run actas_lock_claim team alice "$tb"
  [ "$status" -eq 1 ]
  [ "$output" = "held:$ta" ]

  # State classification agrees from both sides.
  [ "$(actas_lock_state team alice "$ta")" = "mine" ]
  [ "$(actas_lock_state team alice "$tb")" = "other:$ta" ]

  # When the owner pid dies, the lock is reclaimable (stale → free).
  kill "$pa" 2>/dev/null || true
  wait "$pa" 2>/dev/null || true
  [ "$(actas_lock_state team alice "$tb")" = "free" ]

  kill "$pb" 2>/dev/null || true
  wait "$pb" 2>/dev/null || true
}
