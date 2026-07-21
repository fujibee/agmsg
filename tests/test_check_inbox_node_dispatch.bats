#!/usr/bin/env bats

load test_helper

setup() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) skip "Windows-only native dispatch" ;;
  esac
  export TEST_SKILL_DIR="$(mktemp -d)"
  mkdir -p "$TEST_SKILL_DIR/scripts"
  cp -R "$BATS_TEST_DIRNAME"/../scripts/. "$TEST_SKILL_DIR/scripts/"
  export SCRIPTS="$TEST_SKILL_DIR/scripts"
  mkdir -p "$TEST_SKILL_DIR/fake-bin"
  export PATH="$TEST_SKILL_DIR/fake-bin:$PATH"
  export NODE_LOG="$TEST_SKILL_DIR/node.log"
}

teardown() {
  rm -rf "$TEST_SKILL_DIR"
}

write_fake_node() {
  cat > "$TEST_SKILL_DIR/fake-bin/agmsg-test-node" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$NODE_LOG"
exit "${FAKE_NODE_STATUS:?}"
EOF
  chmod +x "$TEST_SKILL_DIR/fake-bin/agmsg-test-node"
  export AGMSG_NODE="$TEST_SKILL_DIR/fake-bin/agmsg-test-node"
}

@test "Windows check-inbox fails loud for a missing authoritative Node override" {
  export AGMSG_NODE="$TEST_SKILL_DIR/fake-bin/missing-node"
  cat > "$SCRIPTS/whoami.sh" <<'EOF'
#!/usr/bin/env bash
echo 'legacy fallback must not run' >&2
exit 42
EOF
  chmod +x "$SCRIPTS/whoami.sh"

  run bash "$SCRIPTS/check-inbox.sh" codex "$TEST_SKILL_DIR/project"
  [ "$status" -eq 127 ]
  [[ "$output" == *"configured Node.js"* ]]
  [[ "$output" != *"legacy fallback must not run"* ]]
}

@test "Windows check-inbox falls back when no Node can be resolved" {
  unset AGMSG_NODE AGMSG_CODEX_NODE
  export PATH="/usr/bin:/bin"
  cat > "$SCRIPTS/whoami.sh" <<'EOF'
#!/usr/bin/env bash
echo 'not_joined=true'
EOF
  chmod +x "$SCRIPTS/whoami.sh"

  run bash "$SCRIPTS/check-inbox.sh" codex "$TEST_SKILL_DIR/project"
  [ "$status" -eq 0 ]
}

@test "Windows check-inbox falls back only for side-effect-free exit 78" {
  write_fake_node
  export FAKE_NODE_STATUS=78
  # Make the legacy path terminate before storage or inbox side effects.
  cat > "$SCRIPTS/whoami.sh" <<'EOF'
#!/usr/bin/env bash
echo 'not_joined=true'
EOF
  chmod +x "$SCRIPTS/whoami.sh"

  run bash "$SCRIPTS/check-inbox.sh" codex "$TEST_SKILL_DIR/project"
  [ "$status" -eq 0 ]
  grep -q 'check-inbox.js codex' "$NODE_LOG"
}

@test "Windows check-inbox treats a non-78 Node failure as authoritative" {
  write_fake_node
  export FAKE_NODE_STATUS=9
  cat > "$SCRIPTS/whoami.sh" <<'EOF'
#!/usr/bin/env bash
echo 'legacy fallback must not run' >&2
exit 42
EOF
  chmod +x "$SCRIPTS/whoami.sh"

  run bash "$SCRIPTS/check-inbox.sh" codex "$TEST_SKILL_DIR/project"
  [ "$status" -eq 9 ]
  [[ "$output" != *"legacy fallback must not run"* ]]
}
