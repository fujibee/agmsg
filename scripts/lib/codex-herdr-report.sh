#!/usr/bin/env bash
# codex-herdr-report.sh — keep herdr's record of a Codex seat's thread on the
# seat's own pane (#1736).
#
# herdr's Codex hook reports "pane <HERDR_PANE_ID> holds thread <id>" on every
# SessionStart, and under Codex's shared app-server daemon HERDR_PANE_ID is the
# pane that STARTED the daemon. So herdr ends up with a seat's thread on the
# starter's pane, and after a herdr restart that pane is resumed into the wrong
# thread (or loses the race against the right pane, depending on pane order).
#
# Once codex-own-pane.sh has PROVEN a seat's own pane, this reports (own pane,
# thread) with pane.report_agent_session under herdr's own Codex source,
# session_start_source=resume, and a seq in the same unit the hook uses
# (nanoseconds since the epoch), so it is newer than the hook's.
#
# The starter's pane is NOT touched. herdr's release-agent matches only the
# pane's source and agent label, never the session id, and takes effect only
# with a seq newer than the pane's last one, so a release would also delete a
# record another seat's SessionStart wrote after we looked. No conditional form
# exists, so the stale claim on the starter's pane is left alone.
#
# It runs only where a pane was just proven (a fresh scan, at most once per
# AGMSG_CODEX_PANE_TTL per thread), never on a cache hit, so a call that hits the
# cache launches nothing extra. It is best effort and silent: any failure leaves
# herdr as it was and changes nothing for the caller. AGMSG_CODEX_HERDR_REPORT=0
# turns it off.
#
# Output: none. Exit status: always 0.

[ -n "${_AGMSG_CODEX_HERDR_REPORT_SH:-}" ] && return 0
_AGMSG_CODEX_HERDR_REPORT_SH=1

_AGMSG_CHR_SOURCE="herdr:codex"
_AGMSG_CHR_AGENT="codex"

# herdr's pane-id grammar, as the driver uses it: wN:pX, letters and digits.
_agmsg_chr_pane_ok() {
  case "$1" in
    '') return 1 ;;
    *[!0-9A-Za-z:]*) return 1 ;;
    *:*) return 0 ;;
  esac
  return 1
}

# seq in the hook's unit. `date` has no %N on macOS, so the end of the current
# second is used: later than any report made earlier, which is the only order
# that matters (the hook's report is what this one follows).
_agmsg_chr_seq() { printf '%s999999999\n' "$(date +%s)"; }

# <socket> <thread> <own pane>
_agmsg_chr_run() {
  local sock="$1" tid="$2" own="$3" json rc=0 rows row pane sess src
  local own_ok=0 seq
  json="$(HERDR_SOCKET_PATH="$sock" herdr agent list 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$json" ] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  rows="$(sqlite3 :memory: -separator '|' \
    "select json_extract(value,'\$.pane_id'),
            coalesce(json_extract(value,'\$.agent_session.value'),''),
            coalesce(json_extract(value,'\$.agent_session.source'),'')
       from json_each('${json//\'/\'\'}', '\$.result.agents')" 2>/dev/null)" || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    pane="${row%%|*}"; row="${row#*|}"; sess="${row%%|*}"; src="${row#*|}"
    if [ "$pane" = "$own" ] && [ "$sess" = "$tid" ] && [ "$src" = "$_AGMSG_CHR_SOURCE" ]; then
      own_ok=1
    fi
  done <<ROWS
$rows
ROWS

  if [ "$own_ok" -eq 0 ]; then
    seq="$(_agmsg_chr_seq)"
    HERDR_SOCKET_PATH="$sock" herdr pane report-agent-session "$own" \
      --source "$_AGMSG_CHR_SOURCE" --agent "$_AGMSG_CHR_AGENT" --seq "$seq" \
      --agent-session-id "$tid" --session-start-source resume >/dev/null 2>&1 || return 0
  fi
  return 0
}

# <thread> <KEY=VALUE lines of the proven TUI environment, on stdin>
agmsg_codex_report_own_session() {
  local tid="$1" line sock="" own="" env1=""
  [ "${AGMSG_CODEX_HERDR_REPORT:-1}" = 0 ] && { cat >/dev/null; return 0; }
  while IFS= read -r line; do
    case "$line" in
      HERDR_ENV=*) env1="${line#*=}" ;;
      HERDR_SOCKET_PATH=*) sock="${line#*=}" ;;
      HERDR_PANE_ID=*) own="${line#*=}" ;;
    esac
  done
  [ "$env1" = 1 ] && [ -n "$sock" ] && [ -n "$tid" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  _agmsg_chr_pane_ok "$own" || return 0
  _agmsg_chr_run "$sock" "$tid" "$own"
  return 0
}
