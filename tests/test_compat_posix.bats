#!/usr/bin/env bats

# Tests for compat_get_comm's POSIX (non-MSYS) branch.
#
# `ps -o comm=` prints the full executable path on macOS. The previous
# implementation piped that through `xargs basename`, which word-splits on
# whitespace and interprets quotes, so any agent installed under a path
# containing a space -- e.g. the Claude Code desktop app, which always lives
# under "~/Library/Application Support/Claude/..." -- resolved to "Application"
# instead of "claude". agmsg_pid_is_agent then never matched, agmsg_agent_pid
# fell back to a bare session id, and every actas lock was GC'd as stale.

load test_helper

skip_if_msys() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip "POSIX-only test (the msys branch is covered by test_compat.bats)" ;;
  esac
}

setup() {
  setup_test_env
  skip_if_msys

  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/compat.sh"
}

teardown() {
  [ -n "${_PROC_PID:-}" ] && kill "$_PROC_PID" 2>/dev/null
  [ -n "${_PROC_PID:-}" ] && wait "$_PROC_PID" 2>/dev/null
  teardown_test_env
}

# Put a stub `ps` first on PATH that prints $1 as the comm field.
_stub_ps_printing() {
  local out="$1" dir="$TEST_SKILL_DIR/psstub"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" %q\n' "$out"
  } > "$dir/ps"
  chmod +x "$dir/ps"
  PATH="$dir:$PATH"
}

# ── stubbed ps: deterministic on every POSIX platform ────────────────────

@test "compat_get_comm returns the binary name when ps reports a path containing spaces" {
  _stub_ps_printing "/Users/u/Library/Application Support/Claude/claude-code/2.1.227/claude.app/Contents/MacOS/claude"

  run compat_get_comm 4242
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "compat_get_comm returns the binary name when ps reports a path containing a quote" {
  _stub_ps_printing "/opt/it's here/claude"

  run compat_get_comm 4242
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "compat_get_comm is unchanged for a path without spaces" {
  _stub_ps_printing "/usr/local/bin/claude"

  run compat_get_comm 4242
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "compat_get_comm fails for a pid ps knows nothing about" {
  local dir="$TEST_SKILL_DIR/psstub"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/ps"
  chmod +x "$dir/ps"
  PATH="$dir:$PATH"

  run compat_get_comm 4242
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ── contract drift guard: the real ps, a real process ────────────────────
#
# The stub above asserts what we believe `ps` does. This test checks that
# belief against the real `ps` on this machine, and skips where the platform
# reports a bare comm (Linux) rather than a path -- there the split is
# unreachable and the stub does not describe local reality.

@test "compat_get_comm matches the real ps for a binary under a space-containing path" {
  local dir="$TEST_SKILL_DIR/Application Support/bin" sleep_bin
  sleep_bin=$(command -v sleep) || skip "no sleep on PATH"
  mkdir -p "$dir"
  # A symlink, not a copy: macOS kills a copied system binary for an invalid
  # code signature (SIGKILL/137), and ps then reports nothing at all.
  ln -s "$sleep_bin" "$dir/claude" || skip "cannot symlink into the test tree"

  "$dir/claude" 30 3>&- &
  _PROC_PID=$!
  sleep 0.5

  local raw
  raw=$(ps -o comm= -p "$_PROC_PID" 2>/dev/null || true)
  case "$raw" in
    */*) ;;
    *) skip "this platform's ps reports a bare comm ([$raw]); the space-splitting path is unreachable here" ;;
  esac

  # The real ps hands us a path with a space -- the premise of the stub above.
  # A non-last `[[ ]]` cannot fail the test on bash 3.2, so this states the
  # premise the way the skip guard above already does.
  case "$raw" in
    *"Application Support"*) ;;
    *) echo "ps reported [$raw], which does not carry the space-containing path" >&2
       return 1 ;;
  esac

  run compat_get_comm "$_PROC_PID"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}
