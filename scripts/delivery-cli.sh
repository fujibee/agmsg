#!/usr/bin/env bash
# `agmsg delivery`: how incoming messages reach this agent, in one place.
#
#   agmsg delivery [status] [--type <type>] [--project <path>]
#   agmsg delivery agmsgd|monitor|turn|both|off [--type <type>] [--project <path>]
#
# It only calls daemon.sh (the install-wide agmsgd) and delivery.sh (this
# project's hooks). The mode values handed to delivery.sh are unchanged:
# `monitor` is only SHOWN as "monitor (legacy)". Choosing agmsgd runs
# `daemon enable` (when it is not on yet) and leaves the project on `monitor` as
# the fallback for a seat whose destination is not confirmed yet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/compat.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/detect-cli-type.sh"

_usage() {
  cat >&2 <<'USAGE'
usage: agmsg delivery [status] [--type <type>] [--project <path>]
       agmsg delivery agmsgd|monitor|turn|both|off [--type <type>] [--project <path>]
USAGE
}

ACTION="status" TYPE="" PROJECT=""
case "${1:-}" in
  status|agmsgd|monitor|turn|both|off) ACTION="$1"; shift ;;
  ''|--*) ;;
  *) _usage; exit 2 ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --type) TYPE="${2:?--type needs a value}"; shift 2 ;;
    --project) PROJECT="${2:?--project needs a value}"; shift 2 ;;
    *) _usage; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || PROJECT="$(pwd)"
[ -n "$TYPE" ] || TYPE="$(agmsg_detect_cli_type)"

offer="$(bash "$SCRIPT_DIR/daemon.sh" offer "$TYPE" 2>/dev/null || true)"

_mode_label() { case "$1" in monitor) printf 'monitor (legacy)' ;; *) printf '%s' "$1" ;; esac; }

case "$ACTION" in
  status)
    case "$offer" in
      agmsgd=on) echo "delivery: agmsgd (on) — notices are delivered directly" ;;
      agmsgd=not-running*) echo "delivery: agmsgd (on, but not running: ${offer#*reason=}) — start it with: agmsg delivery agmsgd" ;;
      agmsgd=available) echo "delivery: agmsgd (off) — available; turn it on with: agmsg delivery agmsgd" ;;
      agmsgd=unavailable*) echo "delivery: agmsgd (unavailable) — ${offer#*reason=}" ;;
      *) echo "delivery: agmsgd (unknown)" ;;
    esac
    out="$(bash "$SCRIPT_DIR/delivery.sh" status "$TYPE" "$PROJECT")"
    mode="$(sed -n 's/^mode: *\([a-z]*\).*/\1/p' <<<"$out" | head -1)"
    if [ -n "$mode" ]; then
      if [ "$offer" = agmsgd=on ]; then
        echo "this project's fallback: $(_mode_label "$mode")"
      else
        echo "this project: $(_mode_label "$mode")"
      fi
    fi
    printf '%s\n' "$out"
    ;;
  agmsgd)
    case "$offer" in
      agmsgd=on) ;;
      agmsgd=not-running*)
        bash "$SCRIPT_DIR/daemon.sh" start || { echo "agmsg delivery: agmsgd is turned on but could not be started; this project's delivery is unchanged" >&2; exit 1; }
        ;;
      agmsgd=available)
        bash "$SCRIPT_DIR/daemon.sh" enable || { echo "agmsg delivery: agmsgd was not turned on; this project's delivery is unchanged" >&2; exit 1; }
        ;;
      agmsgd=unavailable*)
        echo "agmsg delivery: agmsgd is not available here: ${offer#*reason=}" >&2
        exit 1
        ;;
      *) echo "agmsg delivery: could not tell whether agmsgd is available" >&2; exit 1 ;;
    esac
    exec bash "$SCRIPT_DIR/delivery.sh" set monitor "$TYPE" "$PROJECT"
    ;;
  *)
    bash "$SCRIPT_DIR/delivery.sh" set "$ACTION" "$TYPE" "$PROJECT"
    if [ "$offer" = agmsgd=on ]; then
      echo "note: agmsgd is still on; 'agmsg daemon disable' turns it off."
    fi
    ;;
esac
