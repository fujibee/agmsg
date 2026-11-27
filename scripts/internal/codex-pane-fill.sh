#!/usr/bin/env bash
set -uo pipefail

# codex-pane-fill.sh — agmsgd records a Codex seat's pane after the seat asked
# (#2050).
#
# A Codex seat's tool shell runs inside Codex's sandbox, where ps, pgrep and
# sysctl are refused (measured on macOS seatbelt: "Operation not permitted").
# The seat's own pane is proven from the process table (its thread -> the TUI
# that holds it -> that TUI's terminal environment, scripts/lib/codex-own-pane.sh),
# so from inside the sandbox it cannot be proven at all, and actas used to stop
# at "could not be proven". The seat now leaves a request
# (run/codex-pane-request.<thread>, agmsg_codex_pane_request) and agmsgd, which
# runs outside the sandbox, calls this script with it.
#
# The request only names the seat. Nothing in it is trusted beyond that: the
# seat's role-session record must name the same thread (so a stale request from
# a thread the seat has since left is dropped), the CODEX_HOME comes from that
# record, and the pane comes from the same thread -> TUI proof the seat would
# have run itself. Then the pane is written through the seat's own path
# (agmsg_placement_report), with the proven TUI's terminal variables as the only
# terminal environment, exactly as if the seat had run actas outside the sandbox.
#
# The request is removed whatever the outcome, so one request costs one run of
# this script. A seat that is still unrecorded asks again by running actas.
#
# Usage: codex-pane-fill.sh <request-file>
# Prints exactly one line: "state=<state> reason=<reason>", <state> one of
#   recorded     the pane was named and recorded for the seat
#   unrecorded   the pane could not be proven or written; reason says why
#   dropped      the request was malformed or no longer matches the seat

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SKILL_DIR

report() { printf 'state=%s reason=%s\n' "$1" "$(printf '%s' "${2:-}" | tr '\n\t' '  ' | cut -c1-400)"; }

REQ="${1:-}"
[ -n "$REQ" ] && [ -f "$REQ" ] || { report dropped request_missing; exit 0; }
trap 'rm -f "$REQ" 2>/dev/null' EXIT

team="" agent="" thread="" project="" line=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    team=*) team="${line#team=}" ;;
    agent=*) agent="${line#agent=}" ;;
    thread=*) thread="${line#thread=}" ;;
    project=*) project="${line#project=}" ;;
  esac
done <"$REQ"
case "$thread" in ''|*[!A-Za-z0-9-]*) report dropped thread_malformed; exit 0 ;; esac
[ "${REQ##*/}" = "codex-pane-request.$thread" ] || { report dropped request_name_does_not_match_thread; exit 0; }
[ -n "$team" ] && [ -n "$agent" ] && [ -n "$project" ] || { report dropped request_incomplete; exit 0; }

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/role-session.sh" || { report unrecorded role_session_unavailable; exit 0; }
recorded="$(agmsg_role_session_get "$team" "$agent" session)"
[ "$recorded" = "$thread" ] || { report dropped "the seat's role-session no longer names thread $thread"; exit 0; }
[ "$(agmsg_role_session_get "$team" "$agent" type)" = codex ] || { report dropped seat_is_not_codex; exit 0; }
codex_home="$(agmsg_role_session_get "$team" "$agent" codex_home)"
if [ -n "$codex_home" ]; then export CODEX_HOME="$codex_home"; fi

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/codex-own-pane.sh" || { report unrecorded codex_own_pane_unavailable; exit 0; }
answer="$(agmsg_codex_thread_pane "$thread")"
case "$answer" in
  env$'\n'*) ;;
  *) report unrecorded "${answer#unknown$'\t'}"; exit 0 ;;
esac

# The proven TUI's terminal variables replace agmsgd's own. CODEX_THREAD_ID stays
# unset so the naming path takes this environment as the seat's (it has just
# been proven to be), instead of resolving the thread again.
unset TMUX TMUX_PANE HERDR_ENV HERDR_SOCKET_PATH HERDR_PANE_ID CODEX_THREAD_ID CODEX_SANDBOX
while IFS= read -r line; do
  case "$line" in
    HERDR_ENV=*|HERDR_SOCKET_PATH=*|HERDR_PANE_ID=*|TMUX=*|TMUX_PANE=*) export "${line?}" ;;
  esac
done <<EOF
${answer#env$'\n'}
EOF

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/actas-lock.sh" 2>/dev/null || { report unrecorded actas_lock_unavailable; exit 0; }
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/terminal-registry.sh" 2>/dev/null || { report unrecorded terminal_registry_unavailable; exit 0; }
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/placement-report.sh" 2>/dev/null || { report unrecorded placement_report_unavailable; exit 0; }
out="$(agmsg_placement_report "" "$team" "$agent" "$project" codex record "" "" replace_claim 2>&1)" || true
case "$out" in
  *placement=unrecorded*) report unrecorded "${out#*reason=}"; exit 0 ;;
esac
# A quiet return is not a write: read the record back before saying so.
pane="${HERDR_PANE_ID:-${TMUX_PANE:-}}"
rec="$(agmsg_spawn_path "$team" "$agent" 2>/dev/null)" || rec=""
ref=""
[ -n "$rec" ] && [ -f "$rec" ] && IFS="$(printf '\t')" read -r ref _ <"$rec"
case "$ref" in
  *":$pane") report recorded "$ref" ;;
  *) report unrecorded "the pane ($pane) was proven but no record for it was written${out:+: $out}" ;;
esac
exit 0
