#!/usr/bin/env bash
# Where a project's codex app-server can be reached.
#
# codex-monitor.sh is the only writer. It records the port it bound, builds the
# URL from it, and hands that same string to three places:
#
#   codex-monitor.sh:201   printf '%s' "$PORT" > "$PORT_FILE"
#   codex-monitor.sh:212   SOCKET_URL="ws://127.0.0.1:$PORT"
#   codex-monitor.sh:217   export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
#   codex-monitor.sh:228   exec "$REAL_CODEX" --remote "$SOCKET_URL"
#
# So the port file and the environment variable are two carriers of ONE value.
# Reading the file does not invent a second way to reach the server; it
# reconstructs the string the variable would have held, byte for byte.
#
# That matters because the variable does not always arrive. Under codex 0.146
# `--remote`, an agent's shell_command runs inside the app-server process rather
# than the TUI client, and codex-monitor.sh cannot export into that context: the
# URL does not exist until the server's banner has been parsed, which is after
# the server is already running. The value is not missing because nothing set
# it — it is missing because the execution context cannot receive it.
#
# Callers must keep treating "no URL" as "could not ask", never as "asked and
# got nothing". The two are different answers and only the first may fall
# through to a weaker source.

# Echo the app-server URL for <project>, or nothing.
#
# The environment variable wins when present: it is the value monitor exported
# for this very process, and preferring it keeps every context that already
# worked on exactly the path it used before.
_agmsg_codex_app_server_url() {
  local project="$1" port_file port
  [ -n "$project" ] || return 0
  if [ -n "${AGMSG_CODEX_BRIDGE_APP_SERVER:-}" ]; then
    printf '%s' "$AGMSG_CODEX_BRIDGE_APP_SERVER"
    return 0
  fi
  command -v agmsg_sha1 >/dev/null 2>&1 || return 0
  port_file="$SKILL_DIR/run/codex-app-server.$(printf '%s' "$project" | agmsg_sha1 2>/dev/null).port"
  port="$(cat "$port_file" 2>/dev/null || true)"
  # Digits, and a port a TCP stack could have handed out. Digits alone are not
  # enough on their own — a prefix of a real port (5 of 52962) is all digits and
  # is itself a valid port, so this check cannot detect a partial read. The
  # writer publishes atomically for that reason; this bounds the damage of
  # anything else that could leave a stray value here.
  #
  # Length before magnitude: `[ -ge ]` on an unbounded digit string is a
  # comparison on a value that may not fit.
  case "$port" in
    ''|*[!0-9]*|0*) return 0 ;;
  esac
  [ "${#port}" -le 5 ] || return 0
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 0
  printf 'ws://127.0.0.1:%s' "$port"
}
