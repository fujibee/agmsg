#!/usr/bin/env bash
# Where THIS SEAT's codex app-server can be reached (#1254: one app-server
# per seat, never a shared per-project one).
#
# codex-monitor.sh is the only writer. It records the port it bound in this
# seat's own record, builds the URL from it, and hands that same string to:
#
#   codex-monitor.sh   AGMSG_CODEX_SEAT_KEY="$SEAT_KEY" "$REAL_CODEX" app-server ...
#   codex-monitor.sh   the seat record (port=...), via _seat-key.sh's writer
#   codex-monitor.sh   SOCKET_URL="ws://127.0.0.1:$PORT"
#   codex-monitor.sh   export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
#   codex-monitor.sh   export AGMSG_CODEX_SEAT_KEY="$SEAT_KEY"
#   codex-monitor.sh   exec "$REAL_CODEX" --remote "$SOCKET_URL"
#
# So the seat record and the environment variable are two carriers of ONE
# value. Reading the record does not invent a second way to reach the server;
# it reconstructs the string the variable would have held, byte for byte.
#
# That matters because the variable does not always arrive. Under codex 0.146
# `--remote`, an agent's shell_command runs inside the app-server process rather
# than the TUI client, and codex-monitor.sh cannot export AGMSG_CODEX_BRIDGE_
# APP_SERVER into that context: the URL does not exist until the server's
# banner has been parsed, which is after the server is already running. But
# AGMSG_CODEX_SEAT_KEY IS set directly on the app-server's own command (see
# codex-monitor.sh), so the app-server's children inherit THAT instead -- it
# names which seat record to read, never a guess or an ancestry walk.
#
# Callers must keep treating "no URL" as "could not ask", never as "asked and
# got nothing". The two are different answers and only the first may fall
# through to a weaker source. If NEITHER the URL nor a valid seat key reaches
# a caller, the answer is "could not ask" -- never a fall-through to some
# OTHER record.

# Echo the app-server URL for THIS SEAT, or nothing. <project> is accepted for
# call-site compatibility but no longer used to locate anything -- a seat's
# record carries no project lookup key of its own; project matching (where it
# is still needed, e.g. delivery.sh's cleanup) reads the record's own
# `project=` field instead of deriving a path from the project.
_agmsg_codex_app_server_url() {
  local project="$1"
  [ -n "$project" ] || return 0
  if [ -n "${AGMSG_CODEX_BRIDGE_APP_SERVER:-}" ]; then
    printf '%s' "$AGMSG_CODEX_BRIDGE_APP_SERVER"
    return 0
  fi
  local seat_key="${AGMSG_CODEX_SEAT_KEY:-}"
  [ -n "$seat_key" ] || return 0
  if ! command -v _agmsg_codex_seat_key_ok >/dev/null 2>&1; then
    local _sk_dir
    _sk_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    [ -n "$_sk_dir" ] && [ -f "$_sk_dir/_seat-key.sh" ] || return 0
    # shellcheck disable=SC1090,SC1091
    . "$_sk_dir/_seat-key.sh"
  fi
  _agmsg_codex_seat_key_ok "$seat_key" || return 0
  [ -n "${SKILL_DIR:-}" ] || return 0
  local record port
  record="$(_agmsg_codex_seat_record_path "$SKILL_DIR/run" "$seat_key")"
  _agmsg_codex_seat_record_read "$record" || return 0
  port="$SEAT_REC_PORT"
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
