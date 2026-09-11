#!/usr/bin/env bats

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

_install_collision_fixture() {
  local bin="$BATS_TEST_TMPDIR/collision-bin"
  mkdir -p "$bin"
  cat > "$bin/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1/$2" in
  agent/list)
    printf '%s\n' '{"result":{"agents":[{"agent":"","pane_id":"w1:p9","terminal_id":"tm1","tab_id":"t1","workspace_id":"ws1"}]}}'
    ;;
  agent/get)
    if [ "${COLLISION_OCCUPIED:-0}" -eq 1 ]; then
      printf '%s\n' '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
      exit 1
    fi
    ;;
  pane/get)
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p9","agent_status":"idle","label":"","terminal_title":""}}}'
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$bin/herdr"
  export PATH="$bin:$PATH"
}

_join_with_claim() {   # <team> <agent> [ref]
  local team="$1" agent="$2" ref="${3:-herdr:w1:p9}"
  bash "$SCRIPTS/join.sh" "$team" "$agent" claude-code /tmp/proj >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\t/tmp/proj\tclaude-code\n' "$ref" > "$TEST_SKILL_DIR/run/spawn.${team}__${agent}"
}

@test "placement collisions reports different agents across teams and a proven empty pane (#1144)" {
  _install_collision_fixture
  _join_with_claim alpha alice
  _join_with_claim beta alice
  _join_with_claim gamma bob

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "Placement collisions:" <<< "$output"
  grep -Fq "ref: herdr:w1:p9" <<< "$output"
  grep -Fq -- "- alpha/alice" <<< "$output"
  grep -Fq -- "- beta/alice" <<< "$output"
  grep -Fq -- "- gamma/bob" <<< "$output"
  grep -Fq "resident_agent: absent" <<< "$output"
  [ "$(cut -f1 "$TEST_SKILL_DIR/run/spawn.alpha__alice")" = herdr:w1:p9 ]
  [ "$(cut -f1 "$TEST_SKILL_DIR/run/spawn.beta__alice")" = herdr:w1:p9 ]
  [ "$(cut -f1 "$TEST_SKILL_DIR/run/spawn.gamma__bob")" = herdr:w1:p9 ]
}

@test "placement collisions keeps rc2 unknown even when its body says agent_not_found (#1144)" {
  _install_collision_fixture
  _join_with_claim alpha alice
  _join_with_claim beta bob
  cat >> "$TEST_SKILL_DIR/scripts/drivers/terminals/herdr/ops.sh" <<'OPS'
terminal_team_input_ready() {
  printf 'not_ready:agent_not_found\n'
  return 2
}
OPS

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "Placement collisions:" <<< "$output"
  refute grep -Fq "resident_agent: absent" <<< "$output"
}

@test "placement collisions excludes one agent registered in two teams (#1144)" {
  _install_collision_fixture
  _join_with_claim alpha alice
  _join_with_claim beta alice

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "placement collisions never guesses that an occupied pane is empty (#1144)" {
  _install_collision_fixture
  _join_with_claim alpha alice herdr:w1:pA
  _join_with_claim beta bob
  _join_with_claim gamma carol
  export COLLISION_OCCUPIED=1

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq -- "- beta/bob" <<< "$output"
  grep -Fq -- "- gamma/carol" <<< "$output"
  refute grep -Fq -- "- alpha/alice" <<< "$output"
  refute grep -Fq "resident_agent: absent" <<< "$output"
}

@test "placement collisions rejects arguments rather than implying a repair scope (#1144)" {
  run bash "$SCRIPTS/placement-collisions.sh" alpha
  [ "$status" -eq 2 ]
  grep -Fq "Usage: placement-collisions.sh" <<< "$output"
}
