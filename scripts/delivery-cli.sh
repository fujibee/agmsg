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
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SKILL_DIR
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/role-session.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/daemon-state.sh"

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
CANON_PROJECT="$(agmsg_canonical_path "$PROJECT")"

# Record what this project chose, in run/delivery-choice ("<type> <project>
# <value>"): the daemon, the shim and the session hooks read it, so a project that
# chose something other than agmsgd is not delivered to by agmsgd. Only this
# command writes it; a project that never chose has no line and is unchanged.
_choice_write_unlocked() {   # <value>
  local file="$SKILL_DIR/run/delivery-choice" tmp
  mkdir -p "$SKILL_DIR/run" 2>/dev/null || return 1
  tmp="$(mktemp "$SKILL_DIR/run/.delivery-choice.XXXXXX")" || return 1
  {
    [ ! -f "$file" ] || awk -F'\t' -v t="$TYPE" -v p="$CANON_PROJECT" '!($1 == t && $2 == p)' "$file"
    printf '%s\t%s\t%s\n' "$TYPE" "$CANON_PROJECT" "$1"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}
_record_choice() {   # <value>
  case "$CANON_PROJECT" in *$'\t'*|*$'\n'*) echo "agmsg delivery: this project path cannot be recorded; the choice was not saved" >&2; return 1 ;; esac
  _agmsg_role_session_write _choice_write_unlocked "$1" || { echo "agmsg delivery: could not record the choice for this project" >&2; return 1; }
}

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
    chosen="$(agmsg_delivery_choice_get "$TYPE" "$PROJECT")"
    if [ -n "$chosen" ] && [ "$chosen" != agmsgd ]; then
      echo "this project: $(_mode_label "$chosen") chosen — agmsgd does not deliver here"
    elif [ -n "$mode" ]; then
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
    # This session published no destination yet (that happens at the next
    # SessionStart or actas), so it keeps the Monitor the directive below starts.
    # Say so first, so the Monitor instruction does not read as contradicting the choice.
    if [ "$TYPE" = claude-code ]; then
      echo "This session keeps receiving through a Monitor watch until it restarts or runs actas; agmsgd can take over once it confirms this session's destination."
    else
      echo "This session keeps its current delivery until it restarts or runs actas; agmsgd can take over once it confirms this session's destination."
    fi
    bash "$SCRIPT_DIR/delivery.sh" set monitor "$TYPE" "$PROJECT"
    _record_choice agmsgd
    ;;
  *)
    bash "$SCRIPT_DIR/delivery.sh" set "$ACTION" "$TYPE" "$PROJECT"
    _record_choice "$ACTION"
    case "$offer" in
      agmsgd=on|agmsgd=not-running*)
        echo "agmsgd does not deliver to this project now ($(_mode_label "$ACTION") chosen). agmsgd itself stays on for the other projects of this install; to turn it off for all of them: agmsg daemon disable"
        ;;
    esac
    ;;
esac
