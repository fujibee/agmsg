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
# What the seat's role-session says, as one value. It is read before the proof,
# again right before the record is written, and again after it: the seat may
# move to another thread (a new actas, a /clear) while this runs, and a request
# from its old thread must not leave its old TUI's pane as its record.
_agmsg_role_session_path_into "$team" "$agent"
role_path="$_AGMSG_ROLE_SESSION_PATH"
# One read of the record, shell builtins only, into $SNAP and the R_* fields.
role_snapshot() {
  local l
  R_session="" R_type="" R_project="" R_owner="" R_codex_home=""
  if [ -f "$role_path" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
      case "$l" in
        session=*) [ -n "$R_session" ] || R_session="${l#session=}" ;;
        type=*) [ -n "$R_type" ] || R_type="${l#type=}" ;;
        project=*) [ -n "$R_project" ] || R_project="${l#project=}" ;;
        owner=*) [ -n "$R_owner" ] || R_owner="${l#owner=}" ;;
        codex_home=*) [ -n "$R_codex_home" ] || R_codex_home="${l#codex_home=}" ;;
      esac
    done <"$role_path"
  fi
  SNAP="session=$R_session;type=$R_type;project=$R_project;owner=$R_owner;codex_home=$R_codex_home;"
}
role_snapshot; snap="$SNAP"
case "$snap" in
  "session=$thread;type=codex;"*) ;;
  "session=$thread;"*) report dropped seat_is_not_codex; exit 0 ;;
  *) report dropped "the seat's role-session no longer names thread $thread"; exit 0 ;;
esac
# The project and the Codex profile come from the role-session, not the request.
project="$R_project"
[ -n "$project" ] || { report dropped role_session_has_no_project; exit 0; }
if [ -n "$R_codex_home" ]; then export CODEX_HOME="$R_codex_home"; fi

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
rec="$(agmsg_spawn_path "$team" "$agent" 2>/dev/null)" || rec=""
[ -n "$rec" ] || { report unrecorded placement_path_unavailable; exit 0; }
role_snapshot; [ "$SNAP" = "$snap" ] || { report dropped "the seat's role-session changed while its pane was being proven"; exit 0; }
# The seat's own record as it was, so a write that turns out stale can be undone.
before=""; had_before=0
[ -f "$rec" ] && { before="$(cat "$rec")"; had_before=1; }
out="$(agmsg_placement_report "" "$team" "$agent" "$project" codex record "" "" replace_claim 2>&1)" || true
case "$out" in
  *placement=unrecorded*) report unrecorded "${out#*reason=}"; exit 0 ;;
esac
# A quiet return is not a write: read the record back before saying so.
pane="${HERDR_PANE_ID:-${TMUX_PANE:-}}"
ref=""
[ -f "$rec" ] && IFS="$(printf '\t')" read -r ref _ <"$rec"
case "$ref" in
  *":$pane") ;;
  *) report unrecorded "the pane ($pane) was proven but no record for it was written${out:+: $out}"; exit 0 ;;
esac
# The role-session cannot be held locked across the write (the naming path takes
# that lock itself), so it is read once more after it. Changed: the record just
# written may be the old thread's pane, so it is undone -- the seat's previous
# record put back, or none -- unless something else has replaced it meanwhile.
# The worst outcome is then "no record yet", which the seat's own next actas
# fills, never the old TUI's pane standing as its record.
role_snapshot
if [ "$SNAP" != "$snap" ]; then
  now=""; [ -f "$rec" ] && now="$(cat "$rec")"
  case "$now" in
    "$ref"*)
      if [ "$had_before" -eq 1 ]; then agmsg_write_atomic "$rec" "$before" 2>/dev/null || rm -f "$rec"
      else rm -f "$rec"; fi ;;
  esac
  report dropped "the seat's role-session changed while its pane was being recorded; the record was undone"
  exit 0
fi
report recorded "$ref"
exit 0
