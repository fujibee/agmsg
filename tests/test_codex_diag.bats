#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  export DIAG="$TYPES/codex/codex-diag.sh"
}

teardown() { teardown_test_env; }

@test "codex diagnose: help documents read-only exit contract" {
  run bash "$DIAG" --help
  [ "$status" -eq 0 ]
  grep -qF -- "read-only" <<<"$output"
  grep -qF -- "exit 1 means mismatch or unknown" <<<"$output"
  refute grep -qF -- "self-test" <<<"$output"
}

@test "codex diagnose: legacy invocation is unknown and non-match" {
  run bash "$DIAG" "$PROJ" team alice
  [ "$status" -eq 1 ]
  grep -qF -- "codex diagnosis: UNKNOWN" <<<"$output"
  grep -qF -- "thread-evidence: current_count=" <<<"$output"
}

@test "codex diagnose: invalid options are usage errors" {
  run bash "$DIAG" "$PROJ" team alice --self-test
  [ "$status" -eq 2 ]
}

@test "codex diagnose: missing seat and app-server remain UNKNOWN" {
  export AGMSG_CODEX_SEAT_KEY="team/alice"
  run bash "$DIAG" "$PROJ" team alice
  [ "$status" -eq 1 ]
  grep -qF -- "app-server: UNKNOWN" <<<"$output"
  grep -qF -- "thread: UNKNOWN" <<<"$output"
}

@test "codex diagnose: effective home is resolved through shared helper" {
  isolated="$TEST_SKILL_DIR/orca-codex-home"
  mkdir -p "$isolated"
  export AGMSG_CODEX_HOME="$isolated"
  export CODEX_HOME="$TEST_SKILL_DIR/default-codex-home"
  run bash "$DIAG" "$PROJ" team alice
  [ "$status" -eq 1 ]
  grep -qF -- "codex diagnosis: UNKNOWN" <<<"$output"
}

@test "codex diagnose: Windows uses PowerShell probe and does not mix MSYS pids" {
  grep -q 'MINGW\*|MSYS\*|CLANGARM\*' "$TYPES/codex/codex-diag.sh"
  grep -q 'powershell.exe pwsh' "$TYPES/codex/codex-diag.sh"
  ! grep -q 'ps -eo.*MSYSTEM' "$TYPES/codex/codex-diag.sh"
}

@test "codex self-delivery reuses canonical Windows diagnosis" {
  grep -qF -- '"$SCRIPT_DIR/codex-diag.sh" "$PROJECT" "$TEAM" "$AGENT"' "$TYPES/codex/codex-diagnose.sh"
  grep -qF -- 'DIAG_OUTPUT=' "$TYPES/codex/codex-diagnose.sh"
  refute grep -Eq '^[[:space:]]*[^#[:space:]].*ps -eo' "$TYPES/codex/codex-diagnose.sh"
  grep -q 'MINGW\*|MSYS\*|CLANGARM\*' "$TYPES/codex/codex-diag.sh"
}
@test "codex-diagnose keeps opt-in self-delivery options" {
  run bash "$TYPES/codex/codex-diagnose.sh" --help
  [ "$status" -eq 0 ]
  grep -qF -- "--self-test" <<<"$output"
  grep -qF -- "--confirm" <<<"$output"
}
