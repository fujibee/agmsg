#!/usr/bin/env bats

setup() {
  export HOME="$(mktemp -d)"
  export INSTALLED="$HOME/.agents/skills/agmsg"
  export TEST_LOG="$HOME/uninstall-actions.log"
  mkdir -p "$INSTALLED/run" "$INSTALLED/scripts/drivers/types/codex" "$HOME/fakebin"
  : > "$INSTALLED/.agmsg"
  TEST_PID=""

  cat > "$HOME/fakebin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >> "$TEST_LOG"
exit 0
EOF
  chmod +x "$HOME/fakebin/launchctl"
  export PATH="$HOME/fakebin:$PATH"

  cat > "$INSTALLED/scripts/drivers/types/codex/codex-desktop-relayctl.sh" <<'EOF'
#!/usr/bin/env bash
printf 'relayctl %s\n' "$*" >> "$TEST_LOG"
EOF
  chmod +x "$INSTALLED/scripts/drivers/types/codex/codex-desktop-relayctl.sh"
}

teardown() {
  if [ -n "${TEST_PID:-}" ]; then
    kill "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
  fi
  rm -rf "$HOME"
}

@test "uninstall removes a meta-less role job and disables the global Desktop relay" {
  local base="$INSTALLED/run/codex-bridge.deadbeef.team.bob"
  cat > "$base.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key>
  <string>com.agmsg.codex-bridge.deadbeef.team.bob</string>
</dict></plist>
EOF

  run bash "$BATS_TEST_DIRNAME/../uninstall.sh" --yes --keep-data

  [ "$status" -eq 0 ]
  grep -qx "launchctl bootout gui/$(id -u)/com.agmsg.codex-bridge.deadbeef.team.bob" "$TEST_LOG"
  grep -qx 'relayctl disable' "$TEST_LOG"
  [ ! -e "$base.plist" ]
}

@test "uninstall derives the managed label and does not signal a forged pid" {
  local project="$HOME/project" base="$INSTALLED/run/codex-bridge.deadbeef.team.bob"
  mkdir -p "$project"
  sleep 60 &
  TEST_PID=$!
  printf '%s\n' "$TEST_PID" > "$base.pid"
  cat > "$base.meta" <<EOF
project=$project
type=codex
team=team
name=bob
thread=thread-123
launch_label=com.example.unrelated-job
EOF
  cat > "$base.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key>
  <string>com.example.other-unrelated-job</string>
</dict></plist>
EOF

  run bash "$BATS_TEST_DIRNAME/../uninstall.sh" --yes --keep-data

  [ "$status" -eq 0 ]
  kill -0 "$TEST_PID" 2>/dev/null
  grep -qx "launchctl bootout gui/$(id -u)/com.agmsg.codex-bridge.deadbeef.team.bob" "$TEST_LOG"
  ! grep -q 'com.example' "$TEST_LOG"
  [ ! -e "$base.pid" ]
  [ ! -e "$base.meta" ]
  [ ! -e "$base.plist" ]
}
