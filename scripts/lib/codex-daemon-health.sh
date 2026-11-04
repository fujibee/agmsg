#!/usr/bin/env bash
# shellcheck disable=SC2034  # CDH_* are this file's outputs, read by its callers
# Health of the Codex app-server daemon, one per CODEX_HOME (#1886).
#
# A long-running daemon can grow without bound (measured: 18.5 GB RSS after
# 3d19h with 7 idle clients). This only READS and reports: nothing here stops,
# restarts or kills any process. The remediation is printed for a person to run.
#
# Reading is cheap and needs no root: daemon.pid for the pid, one `ps` for age
# and start time, one `footprint` for the memory footprint (0.1-0.2 s; `top -l 1`
# took 5-7 s and several seconds of system CPU). Footprint, not RSS (RSS
# swings with paging). There is no CPU signal on purpose: CPU comes in bursts
# unrelated to memory.
#
# Sourced by doctor.sh and by codex-daemon-health.sh (which agmsgd runs).

AGMSG_CODEX_DAEMON_FOOTPRINT_LIMIT_MB=6144
AGMSG_CODEX_DAEMON_AGE_LIMIT_SECONDS=43200

# One profile directory per line: this environment's own (CODEX_HOME, else
# ~/.codex) plus every codex_home= recorded for a seat in <run_dir>. Only
# existing directories, each once.
agmsg_codex_daemon_profiles() {   # <run_dir>
  local run_dir="${1:-}" own seen="" dir
  own="${CODEX_HOME:-${HOME:+$HOME/.codex}}"
  {
    [ -z "$own" ] || printf '%s\n' "$own"
    if [ -n "$run_dir" ]; then
      set -- "$run_dir"/role-session.*
      # One sed for every record, however many seats there are.
      [ ! -e "$1" ] || sed -n 's/^codex_home=//p' "$@" 2>/dev/null
    fi
  } | while IFS= read -r dir; do
    case "$dir" in /*) ;; *) continue ;; esac
    [ -d "$dir" ] || continue
    case $'\n'"$seen" in *$'\n'"$dir"$'\n'*) continue ;; esac
    seen="$seen$dir"$'\n'
    printf '%s\n' "$dir"
  done
}

# [[dd-]hh:]mm:ss -> seconds. Empty on anything else.
_agmsg_codex_daemon_etime_seconds() {
  local e="${1:-}" d=0 h=0 m s
  case "$e" in *[!0-9:-]*|'') return 1 ;; esac
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  case "$e" in
    *:*:*) h="${e%%:*}"; e="${e#*:}" ;;
  esac
  m="${e%%:*}"; s="${e#*:}"
  printf '%s\n' $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# Bytes -> whole MB (rounded down). Empty on anything but digits.
_agmsg_codex_daemon_bytes_mb() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' $(( $1 / 1048576 ))
}

# kill -0 alone reads EPERM as "gone"; the shared helper tells the two apart and
# only a proven ESRCH counts as gone.
_agmsg_cdh_pid_alive() {
  if ! command -v _agmsg_pid_alive_local >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/instance-id.sh" 2>/dev/null || { kill -0 "$1" 2>/dev/null; return; }
  fi
  _agmsg_pid_alive_local "$1"
}

# Scan every profile under <run_dir> and call <callback> <profile> for each, after
# setting (and printing nothing):
#   CDH_STATE      absent | stale | running | unchecked
#   CDH_REASON     why, for stale / unchecked
#   CDH_PID CDH_START  (running or stale)
#   CDH_AGE_SECONDS    (running)
#   CDH_FOOTPRINT_MB CDH_PEAK_MB   (running AND at least the age limit old; empty
#                                    for a younger daemon, which cannot be over)
#   CDH_OVER       1 or 0
#   CDH_CLIENTS    only when over the limit; empty when it could not be counted
# Spawns: one single-pid ps per live daemon, plus per daemon at least 12 h old one
# footprint, and readlink/lsof/grep only for
# one that is over; a footprint or lsof that takes over AGMSG_CODEX_DAEMON_READ_SECONDS
# (5) is killed and that profile reads unchecked, so a slow one cannot starve the
# profiles after it. A temp file (mktemp, rm) is used once the first footprint runs. uname once per process, one sed for all seat records.
# The callback runs as each profile is finished, so a caller that is cut off
# part-way still has the earlier profiles.
agmsg_codex_daemon_scan() {   # <run_dir> <callback>
  local run_dir="${1:-}" cb="${2:-}" profile i n=0 pids="" pid json pidfile
  local -a profiles=() st=() rs=() pd=() sr=()
  while IFS= read -r profile; do
    [ -z "$profile" ] || profiles+=("$profile")
  done <<< "$(agmsg_codex_daemon_profiles "$run_dir")"
  n="${#profiles[@]}"
  [ "$n" -gt 0 ] || return 0
  [ -n "${_AGMSG_CDH_OS:-}" ] || _AGMSG_CDH_OS="$(uname -s)"
  if [ "$_AGMSG_CDH_OS" != Darwin ]; then
    for ((i = 0; i < n; i++)); do
      _agmsg_cdh_reset; CDH_STATE=unchecked CDH_REASON="not checked on this platform"
      "$cb" "${profiles[$i]}"
    done
    return 0
  fi
  # Phase 1: each pid file, and whether its pid is alive. No process is spawned.
  for ((i = 0; i < n; i++)); do
    st[i]=absent; rs[i]=""; pd[i]=""; sr[i]=""
    pidfile="${profiles[$i]}/app-server-daemon/daemon.pid"
    [ -f "$pidfile" ] || continue
    json="$(<"$pidfile")" 2>/dev/null || json=""
    if ! [[ "$json" =~ \"pid\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      st[i]=stale; rs[i]="daemon.pid has no pid"; continue
    fi
    pd[i]="${BASH_REMATCH[1]}"
    # shellcheck disable=SC2086  # splitting collapses the date's padding spaces
    if [[ "$json" =~ \"processStartTime\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then set -f; set -- ${BASH_REMATCH[1]}; set +f; sr[i]="$*"; fi
    if _agmsg_cdh_pid_alive "${pd[$i]}"; then
      st[i]=alive; pids="${pids:+$pids }${pd[$i]}"
    else
      st[i]=stale; rs[i]="pid ${pd[$i]} is not running"
    fi
  done
  # One ps per live daemon, not one for all together: measured on macOS, a ps
  # naming two pids takes about 0.55 s (it walks the whole process table), while
  # a ps naming one takes about 8 ms, so two single-pid calls are 30x cheaper.
  _AGMSG_CDH_PS=""
  for pid in $pids; do
    _AGMSG_CDH_PS="${_AGMSG_CDH_PS}$(ps -o pid=,etime=,lstart= -p "$pid" 2>/dev/null)"$'\n'
  done
  # Phase 2: age, pid reuse, footprint (only from the age limit on).
  for ((i = 0; i < n; i++)); do
    _agmsg_cdh_reset
    CDH_STATE="${st[$i]}" CDH_REASON="${rs[$i]}" CDH_PID="${pd[$i]}" CDH_START="${sr[$i]}"
    [ "$CDH_STATE" != alive ] || _agmsg_cdh_finish "${profiles[$i]}"
    "$cb" "${profiles[$i]}"
  done
  if [ -n "${_AGMSG_CDH_TMP:-}" ]; then
    rm -f "$_AGMSG_CDH_TMP"
    _AGMSG_CDH_TMP=""
  fi
}

_agmsg_cdh_reset() {
  CDH_STATE=absent CDH_REASON="" CDH_PID="" CDH_START="" CDH_AGE_SECONDS="" CDH_FOOTPRINT_MB="" CDH_PEAK_MB="" CDH_OVER=0 CDH_CLIENTS=""
}

# Runs <cmd...> with its stdout in <outfile>, giving up on it after the read limit
# (AGMSG_CODEX_DAEMON_READ_SECONDS, default 5) so one slow or hung daemon cannot
# starve the profiles after it. The child is killed on timeout; returns 1 then.
# The pid is kept in _AGMSG_CDH_CHILD so a caller's TERM trap can reap it.
_agmsg_cdh_bounded() {   # <outfile> <cmd...>
  local out="$1" limit="${AGMSG_CODEX_DAEMON_READ_SECONDS:-5}" ticks=0 rc=0
  shift
  case "$limit" in ''|*[!0-9]*|0) limit=5 ;; esac
  "$@" > "$out" 2>/dev/null &
  _AGMSG_CDH_CHILD=$!
  while kill -0 "$_AGMSG_CDH_CHILD" 2>/dev/null; do
    if [ "$ticks" -ge $(( limit * 10 )) ]; then
      kill "$_AGMSG_CDH_CHILD" 2>/dev/null
      wait "$_AGMSG_CDH_CHILD" 2>/dev/null
      _AGMSG_CDH_CHILD=""
      return 1
    fi
    sleep 0.1
    ticks=$(( ticks + 1 ))
  done
  wait "$_AGMSG_CDH_CHILD" 2>/dev/null || rc=$?
  _AGMSG_CDH_CHILD=""
  return "$rc"
}

# Kills the read in flight, if any. For a caller's TERM/INT trap.
agmsg_codex_daemon_reap_child() {
  [ -z "${_AGMSG_CDH_CHILD:-}" ] || kill "$_AGMSG_CDH_CHILD" 2>/dev/null
  return 0
}

# A live pid: match it to the shared ps output, then read its footprint if it is
# old enough to matter.
_agmsg_cdh_finish() {   # <profile dir>
  local profile="${1:-}" line pid etime lstart fpout bytes peak sock n
  etime="" lstart=""
  while IFS= read -r line; do
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    [ "${1:-}" = "$CDH_PID" ] || continue
    etime="${2:-}"; shift 2 2>/dev/null || true; lstart="$*"
    break
  done <<< "${_AGMSG_CDH_PS:-}"
  pid="$CDH_PID"
  if [ -z "$etime" ]; then
    CDH_STATE=unchecked CDH_REASON="could not read the daemon's age"; return 0
  fi
  if [ -n "$CDH_START" ] && [ -n "$lstart" ] && [ "$lstart" != "$CDH_START" ]; then
    CDH_STATE=stale CDH_REASON="pid $pid now belongs to a different process"; return 0
  fi
  CDH_AGE_SECONDS="$(_agmsg_codex_daemon_etime_seconds "$etime")" || {
    CDH_STATE=unchecked CDH_REASON="could not read the daemon's age"; return 0
  }
  CDH_STATE=running
  [ "$CDH_AGE_SECONDS" -ge "$AGMSG_CODEX_DAEMON_AGE_LIMIT_SECONDS" ] || return 0
  [ -n "${_AGMSG_CDH_TMP:-}" ] || _AGMSG_CDH_TMP="$(mktemp 2>/dev/null)" || _AGMSG_CDH_TMP=""
  fpout=""
  if [ -n "$_AGMSG_CDH_TMP" ] && _agmsg_cdh_bounded "$_AGMSG_CDH_TMP" footprint -p "$pid" --noCategories -f bytes; then
    fpout="$(<"$_AGMSG_CDH_TMP")"
  fi
  [[ "$fpout" =~ phys_footprint:[[:space:]]*([0-9]+) ]] && bytes="${BASH_REMATCH[1]}" || bytes=""
  CDH_FOOTPRINT_MB="$(_agmsg_codex_daemon_bytes_mb "$bytes")" || {
    CDH_STATE=unchecked CDH_REASON="could not read the daemon's memory footprint"; return 0
  }
  [[ "$fpout" =~ phys_footprint_peak:[[:space:]]*([0-9]+) ]] && peak="${BASH_REMATCH[1]}" || peak=""
  CDH_PEAK_MB="$(_agmsg_codex_daemon_bytes_mb "$peak")" || CDH_PEAK_MB=""
  if [ "$CDH_FOOTPRINT_MB" -ge "$AGMSG_CODEX_DAEMON_FOOTPRINT_LIMIT_MB" ]; then
    CDH_OVER=1
    sock="$(readlink "$profile/app-server-control/app-server-control.sock" 2>/dev/null)" || sock=""
    if [ -n "$sock" ]; then
      if _agmsg_cdh_bounded "$_AGMSG_CDH_TMP" lsof -a -p "$pid" -U; then
        n="$(grep -cF "$sock" "$_AGMSG_CDH_TMP")" || n=0
        [ "$n" -gt 0 ] && CDH_CLIENTS=$(( n - 1 ))
      fi
    fi
  fi
  return 0
}

# "3d19h" style age for messages.
agmsg_codex_daemon_age_text() {   # <seconds>
  local s="${1:-0}"
  if [ "$s" -ge 86400 ]; then printf '%sd%sh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
  elif [ "$s" -ge 3600 ]; then printf '%sh%sm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else printf '%sm' $(( s / 60 )); fi
}

agmsg_codex_daemon_footprint_text() {   # <MB>
  local mb="${1:-0}"
  if [ "$mb" -ge 1024 ]; then printf '%s.%s GB' $(( mb / 1024 )) $(( mb % 1024 * 10 / 1024 )); else printf '%s MB' "$mb"; fi
}

# The warning text, one line. Printing the remediation is all this does.
agmsg_codex_daemon_warning_text() {   # <profile dir>
  local clients=""
  [ -z "${CDH_CLIENTS:-}" ] || clients=" with ${CDH_CLIENTS:-} client(s)"
  printf 'Codex app-server daemon (pid %s) for %s has run %s%s and holds %s, over the %s / %sh limit. It keeps running. To restart it: CODEX_HOME=%s codex app-server daemon restart (idle TUIs reconnect by themselves in about 6 s and keep their drafts; running turns drain for up to 60 s).' \
    "${CDH_PID:-}" "$1" "$(agmsg_codex_daemon_age_text "${CDH_AGE_SECONDS:-}")" "$clients" \
    "$(agmsg_codex_daemon_footprint_text "${CDH_FOOTPRINT_MB:-}")" \
    "$(agmsg_codex_daemon_footprint_text "$AGMSG_CODEX_DAEMON_FOOTPRINT_LIMIT_MB")" \
    $(( AGMSG_CODEX_DAEMON_AGE_LIMIT_SECONDS / 3600 )) "$1"
}
