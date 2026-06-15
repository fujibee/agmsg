#!/usr/bin/env bats

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

powershell_bin() {
  command -v pwsh 2>/dev/null ||
    command -v powershell.exe 2>/dev/null ||
    command -v powershell 2>/dev/null
}

@test "windows powershell launcher smoke" {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) skip "native Windows PowerShell smoke" ;;
  esac

  local ps
  ps="$(powershell_bin)" || skip "PowerShell is not available"

  run "$ps" -NoProfile -ExecutionPolicy Bypass -File "$REPO_ROOT/tests/smoke_windows_powershell.ps1" -RepoRoot "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "windows powershell smoke ok" ]]
}

@test "windows powershell launcher source does not hardcode team or agent names" {
  local launcher="$REPO_ROOT/scripts/windows/agmsg.ps1"
  local dispatcher="$REPO_ROOT/scripts/dispatch.sh"
  [ -f "$launcher" ]
  [ -f "$dispatcher" ]
  ! grep -q "AGMSG_TEAM.*emeria" "$launcher"
  ! grep -q "AGMSG_AGENT.*codex" "$launcher"
  ! grep -q "claude-fable" "$launcher"
  ! grep -q "AGMSG_TEAM.*emeria" "$dispatcher"
  ! grep -q "AGMSG_AGENT.*codex" "$dispatcher"
  ! grep -q "claude-fable" "$dispatcher"
}
