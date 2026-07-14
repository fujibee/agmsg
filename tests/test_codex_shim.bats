#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  export CALL_LOG="$TEST_PROJECT/calls.log"

  export FAKE_CODEX="$TEST_PROJECT/real-codex"
  cat > "$FAKE_CODEX" <<'EOF'
#!/usr/bin/env bash
printf 'real-codex' >> "$CALL_LOG"
for arg in "$@"; do
  printf ' <%s>' "$arg" >> "$CALL_LOG"
done
printf '\n' >> "$CALL_LOG"
EOF
  chmod +x "$FAKE_CODEX"

  export FAKE_MONITOR="$TEST_PROJECT/monitor"
  cat > "$FAKE_MONITOR" <<'EOF'
#!/usr/bin/env bash
printf 'monitor real=%s' "${AGMSG_REAL_CODEX:-}" >> "$CALL_LOG"
for arg in "$@"; do
  printf ' <%s>' "$arg" >> "$CALL_LOG"
done
printf '\n' >> "$CALL_LOG"
EOF
  chmod +x "$FAKE_MONITOR"
}

teardown() {
  rm -rf "$TEST_PROJECT"
  teardown_test_env
}

@test "codex shim: monitor project routes resume through codex-monitor" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" bash "$TYPES/codex/codex-shim.sh" resume --last'

  [ "$status" -eq 0 ]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <resume> <--> <--last>" "$CALL_LOG"
}

@test "codex shim: monitor project routes prompt launches through top-level codex" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" bash "$TYPES/codex/codex-shim.sh" "fix this"'

  [ "$status" -eq 0 ]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <codex> <--> <fix this>" "$CALL_LOG"
}

@test "codex shim: non-monitor project passes through to real codex" {
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null

  AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" \
    run bash "$TYPES/codex/codex-shim.sh" resume --last

  [ "$status" -eq 0 ]
  grep -q "real-codex <resume> <--last>" "$CALL_LOG"
  ! grep -q "^monitor" "$CALL_LOG"
}

@test "codex shim: noninteractive codex subcommands pass through even in monitor mode" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" \
    run bash "$TYPES/codex/codex-shim.sh" exec echo hi

  [ "$status" -eq 0 ]
  grep -q "real-codex <exec> <echo> <hi>" "$CALL_LOG"
  ! grep -q "^monitor" "$CALL_LOG"
}

@test "codex shim: --cd project is used for monitor detection" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" \
    run bash "$TYPES/codex/codex-shim.sh" --cd "$TEST_PROJECT" resume

  [ "$status" -eq 0 ]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <resume> <--> <--cd> <$TEST_PROJECT>" "$CALL_LOG"
}

@test "codex shim install: default prints shell function without installing bin wrapper" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME"

  run bash "$TYPES/codex/codex-shim-install.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex() {"* ]]
  [[ "$output" == *"codex-shim.sh"* ]]
  [ ! -e "$HOME/.agents/bin/codex" ]
}

@test "codex shim function: existing agmsg PATH wrapper is skipped when resolving real codex" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  bash "$TYPES/codex/codex-shim-install.sh" install >/dev/null
  [ -x "$HOME/.agents/bin/codex" ]

  local real_bin="$TEST_PROJECT/real-bin"
  mkdir -p "$real_bin"
  cp "$FAKE_CODEX" "$real_bin/codex"
  chmod +x "$real_bin/codex"

  PATH="$HOME/.agents/bin:$real_bin:$PATH" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" \
    run bash -c 'eval "$("$TYPES/codex/codex-shim-install.sh" function)"; cd "$TEST_PROJECT"; codex resume --last'

  [ "$status" -eq 0 ]
  grep -Fq "monitor real=$real_bin/codex <--project> <$TEST_PROJECT> <--codex-command> <resume> <--> <--last>" "$CALL_LOG"
  ! grep -Fq "monitor real=$HOME/.agents/bin/codex" "$CALL_LOG"
}

@test "codex shim function: non-agmsg PATH codex remains eligible as real codex" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/bin"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  cp "$FAKE_CODEX" "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"

  PATH="$HOME/.agents/bin:$PATH" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" \
    run bash -c 'eval "$("$TYPES/codex/codex-shim-install.sh" function)"; cd "$TEST_PROJECT"; codex resume --last'

  [ "$status" -eq 0 ]
  grep -Fq "monitor real=$HOME/.agents/bin/codex <--project> <$TEST_PROJECT> <--codex-command> <resume> <--> <--last>" "$CALL_LOG"
}

@test "codex shim install: installed bin wrapper still finds skill scripts" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  bash "$TYPES/codex/codex-shim-install.sh" install >/dev/null
  [ -x "$HOME/.agents/bin/codex" ]

  PATH="$HOME/.agents/bin:$PATH" run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" codex resume'

  [ "$status" -eq 0 ]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <resume> <-->" "$CALL_LOG"
}
