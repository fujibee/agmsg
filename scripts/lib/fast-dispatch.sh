#!/usr/bin/env bash
# Windows-only native Node dispatcher for latency-sensitive CLI entry points.
# Return 78 only when the native path is unavailable before it can perform a
# side effect. Any other Node exit status is authoritative and must stay loud.

agmsg_fast_try() {
  [ "${OS:-}" = "Windows_NT" ] || return 78

  local script_dir fast_script node_bin
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fast_script="$script_dir/agmsg-fast.js"
  [ -f "$fast_script" ] || return 78

  # shellcheck disable=SC1091
  source "$script_dir/lib/node.sh"
  node_bin="$(agmsg_resolve_node)"
  if ! command -v "$node_bin" >/dev/null 2>&1 && [ ! -x "$node_bin" ]; then
    if [ -n "${AGMSG_NODE:-}" ] || [ -n "${AGMSG_CODEX_NODE:-}" ]; then
      # Explicit overrides are authoritative in lib/node.sh. Keep a typo loud
      # rather than hiding it behind the slower Bash implementation.
      echo "agmsg: configured Node executable is not runnable: $node_bin" >&2
      return 127
    fi
    return 78
  fi

  NODE_NO_WARNINGS=1 "$node_bin" "$fast_script" "$@"
}

agmsg_fast_dispatch() {
  local status
  if agmsg_fast_try "$@"; then
    exit 0
  else
    status=$?
  fi
  [ "$status" -eq 78 ] || exit "$status"
}
