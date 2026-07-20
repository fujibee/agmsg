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

@test "codex shim: monitor project forwards a flags-only launch to codex-monitor (#386)" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" bash "$TYPES/codex/codex-shim.sh" --yolo'

  [ "$status" -eq 0 ]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <codex> <--> <--yolo>" "$CALL_LOG"
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

@test "codex shim: a raw symlink install still resolves its own script location (#387)" {
  # Installing codex-shim.sh directly as a symlink (ln -s .../codex-shim.sh
  # ~/.agents/bin/codex) is a documented install method -- the header comment
  # says exactly this. Before #387, dirname "$0" resolved to the symlink's
  # OWN directory rather than the real script's, so the relative delivery.sh
  # lookup pointed nowhere and the shim silently fell through to plain codex
  # with zero signal, in every monitor-mode project, unconditionally.
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/bin"
  ln -s "$TYPES/codex/codex-shim.sh" "$HOME/.agents/bin/codex"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  PATH="$HOME/.agents/bin:$PATH" run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" codex resume'

  [ "$status" -eq 0 ]
  [[ "$output" != *"cannot find delivery.sh"* ]]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <resume> <-->" "$CALL_LOG"
}

@test "codex shim: _agmsg_resolve_self follows a relative-target symlink (#387)" {
  # A direct unit test of the resolution helper (extracted verbatim from the
  # shipped script via awk, so this exercises the real implementation) rather
  # than a full shim invocation -- avoids needing to fabricate a whole
  # relative skill-tree layout just to get a relative `ln -s` target that
  # still resolves to a real delivery.sh. Covers the non-absolute branch of
  # its target-reconstruction (`ln -s ../real/target.sh link`, as opposed to
  # an absolute target).
  local helper="$TEST_PROJECT/resolve-self.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    awk '/^_agmsg_resolve_self\(\)/,/^}/' "$TYPES/codex/codex-shim.sh"
    echo '_agmsg_resolve_self "$1"'
  } > "$helper"

  mkdir -p "$TEST_PROJECT/real/deep" "$TEST_PROJECT/bin"
  : > "$TEST_PROJECT/real/deep/target.sh"
  ln -s "../real/deep/target.sh" "$TEST_PROJECT/bin/link"

  run bash "$helper" "$TEST_PROJECT/bin/link"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_PROJECT/real/deep/target.sh" ]
}

@test "codex shim: _agmsg_resolve_self follows a multi-hop symlink chain (#387)" {
  local helper="$TEST_PROJECT/resolve-self.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    awk '/^_agmsg_resolve_self\(\)/,/^}/' "$TYPES/codex/codex-shim.sh"
    echo '_agmsg_resolve_self "$1"'
  } > "$helper"

  mkdir -p "$TEST_PROJECT/real" "$TEST_PROJECT/hop" "$TEST_PROJECT/bin"
  : > "$TEST_PROJECT/real/target.sh"
  ln -s "$TEST_PROJECT/real/target.sh" "$TEST_PROJECT/hop/hop1"
  ln -s "$TEST_PROJECT/hop/hop1" "$TEST_PROJECT/bin/link"

  run bash "$helper" "$TEST_PROJECT/bin/link"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_PROJECT/real/target.sh" ]
}

@test "codex shim: a multi-hop symlink chain still resolves its own script location (#387)" {
  # symlink -> symlink -> real script. _agmsg_resolve_self's while loop must
  # keep following until it reaches a non-symlink.
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/bin" "$HOME/intermediate"
  ln -s "$TYPES/codex/codex-shim.sh" "$HOME/intermediate/codex-hop1"
  ln -s "$HOME/intermediate/codex-hop1" "$HOME/.agents/bin/codex"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  PATH="$HOME/.agents/bin:$PATH" run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" codex resume'

  [ "$status" -eq 0 ]
  [[ "$output" != *"cannot find delivery.sh"* ]]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <resume> <-->" "$CALL_LOG"
}

@test "codex shim: a broken install (missing delivery.sh) warns loudly instead of silently passing through (#387)" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/bin"
  # A shim copied somewhere with no skill tree above it at all -- SCRIPT_DIR
  # resolves fine, but the relative delivery.sh three levels up genuinely
  # does not exist. This must be reported, not treated as "not a monitor
  # project".
  cp "$TYPES/codex/codex-shim.sh" "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"

  PATH="$HOME/.agents/bin:$PATH" run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" codex'

  [ "$status" -eq 0 ]
  [[ "$output" =~ "cannot find delivery.sh" ]]
  grep -q "real-codex" "$CALL_LOG"
}
