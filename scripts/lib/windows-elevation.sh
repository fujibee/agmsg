#!/usr/bin/env bash
# Whether this shell is an elevated (administrator) Windows shell.
#
# Codex on Windows refuses to start its shared background server from an
# elevated shell, so a plain `codex` launched there stops with
# "start the Windows daemon from a non-elevated terminal". agmsg asks this
# before it hands a top-level `codex` launch to the real binary, so it can add
# `--no-daemon` (the flag Codex names for exactly this case) only when needed.
#
# AGMSG_WINDOWS_ELEVATED=1 or 0 forces the answer (a test seam, and the way to
# turn the behaviour off if the probe is ever wrong). Anything that is not a
# Windows-on-bash environment answers "not elevated" without running a probe.

# Returns 0 when this shell is elevated on Windows, 1 otherwise.
agmsg_windows_shell_elevated() {
  case "${AGMSG_WINDOWS_ELEVATED:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) return 1 ;;
  esac
  # The native whoami reports the mandatory integrity level; S-1-16-12288 is
  # "High", which is what an elevated token carries. The MSYS whoami does not
  # understand /groups, so the native one is addressed by path, and MSYS path
  # conversion is turned off so the "/groups" argument reaches it untouched.
  local sysroot whoami_exe
  sysroot="${SYSTEMROOT:-${SystemRoot:-C:\\Windows}}"
  if command -v cygpath >/dev/null 2>&1; then
    sysroot="$(cygpath -u "$sysroot" 2>/dev/null || printf '%s' "$sysroot")"
  fi
  whoami_exe="$sysroot/System32/whoami.exe"
  [ -x "$whoami_exe" ] || return 1
  MSYS_NO_PATHCONV=1 "$whoami_exe" /groups 2>/dev/null | grep -q 'S-1-16-12288'
}

# Returns 0 when a plain Codex launch with the arguments "$@" should get
# --no-daemon added: the shell is elevated, and the arguments neither already
# carry --no-daemon (Codex rejects it twice) nor --remote (Codex rejects the
# pair, and a --remote launch does not start the shared server anyway).
# Arguments after a literal -- are prompt text and are not looked at.
agmsg_codex_plain_launch_wants_no_daemon() {
  agmsg_windows_shell_elevated || return 1
  local arg
  for arg in "$@"; do
    case "$arg" in
      --) break ;;
      --remote|--remote=*|--no-daemon) return 1 ;;
    esac
  done
  return 0
}
