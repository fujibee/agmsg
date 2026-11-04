#!/usr/bin/env bash
# shellcheck disable=SC2034  # CDH_* are this file's outputs, read by its callers
# Health of the Codex app-server daemon, one per CODEX_HOME (#1886).
#
# A long-running daemon can grow without bound (measured: 18.5 GB RSS after
# 3d19h with 7 idle clients). This only READS and reports: nothing here stops,
# restarts or kills any process. The remediation is printed for a person to run.
#
# Reading is cheap and needs no root: daemon.pid for the pid, one `ps` for age
# and start time, one `top` for the memory footprint. Footprint, not RSS (RSS
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
  local run_dir="${1:-}" own seen="" dir f
  own="${CODEX_HOME:-${HOME:+$HOME/.codex}}"
  {
    [ -z "$own" ] || printf '%s\n' "$own"
    if [ -n "$run_dir" ]; then
      for f in "$run_dir"/role-session.*; do
        [ -f "$f" ] || continue
        sed -n 's/^codex_home=//p' "$f" 2>/dev/null
      done
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

# "2464K", "12M+", "2.7G" (top -stats mem) -> whole MB. Empty on anything else.
_agmsg_codex_daemon_mem_mb() {
  local v="${1:-}" unit num int frac=0
  v="${v%[+-]}"
  unit="${v: -1}"
  num="${v%?}"
  case "$num" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac
  int="${num%%.*}"
  case "$num" in *.*) frac="${num#*.}"; frac="${frac:0:1}" ;; esac
  [ -n "$int" ] || int=0
  case "$unit" in
    K) printf '%s\n' $(( int / 1024 )) ;;
    M) printf '%s\n' "$int" ;;
    G) printf '%s\n' $(( int * 1024 + 10#${frac:-0} * 1024 / 10 )) ;;
    T) printf '%s\n' $(( int * 1048576 + 10#${frac:-0} * 1048576 / 10 )) ;;
    *) return 1 ;;
  esac
}

# Probe one profile. Sets, and prints nothing:
#   CDH_STATE      absent | stale | running | unchecked
#   CDH_REASON     why, for stale / unchecked
#   CDH_PID CDH_START  (running or stale)
#   CDH_AGE_SECONDS CDH_FOOTPRINT_MB CDH_OVER (running; OVER is 1 or 0)
#   CDH_CLIENTS    only when over the limit; empty when it could not be counted
# Spawns: ps 1 + top 1 for a live daemon; readlink/lsof/grep only when over.
# A daemon younger than the age limit can never be over, so `top` (the slow
# read: several seconds of system CPU on a busy machine) is skipped for it unless
# <always> is given -- doctor passes it to show the footprint.
agmsg_codex_daemon_probe() {   # <profile dir> [always]
  local profile="${1:-}" always="${2:-}" pidfile json pid start psout etime lstart topout mem sock n
  CDH_STATE=absent CDH_REASON="" CDH_PID="" CDH_START="" CDH_AGE_SECONDS="" CDH_FOOTPRINT_MB="" CDH_OVER=0 CDH_CLIENTS=""
  case "$(uname -s)" in
    Darwin) ;;
    *) CDH_STATE=unchecked CDH_REASON="not checked on this platform"; return 0 ;;
  esac
  pidfile="$profile/app-server-daemon/daemon.pid"
  [ -f "$pidfile" ] || return 0
  json="$(cat "$pidfile" 2>/dev/null)" || json=""
  [[ "$json" =~ \"pid\"[[:space:]]*:[[:space:]]*([0-9]+) ]] || { CDH_STATE=stale CDH_REASON="daemon.pid has no pid"; return 0; }
  pid="${BASH_REMATCH[1]}"
  start=""
  # shellcheck disable=SC2086  # splitting collapses the date's padding spaces
  [[ "$json" =~ \"processStartTime\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && { set -f; set -- ${BASH_REMATCH[1]}; set +f; start="$*"; }
  CDH_PID="$pid" CDH_START="$start"
  if ! kill -0 "$pid" 2>/dev/null; then
    CDH_STATE=stale CDH_REASON="pid $pid is not running"; return 0
  fi
  psout="$(ps -o etime=,lstart= -p "$pid" 2>/dev/null)" || psout=""
  set -f
  # shellcheck disable=SC2086
  set -- $psout
  set +f
  etime="${1:-}"; shift 2>/dev/null || true
  lstart="$*"
  if [ -n "$start" ] && [ -n "$lstart" ] && [ "$lstart" != "$start" ]; then
    CDH_STATE=stale CDH_REASON="pid $pid now belongs to a different process"; return 0
  fi
  CDH_AGE_SECONDS="$(_agmsg_codex_daemon_etime_seconds "$etime")" || {
    CDH_STATE=unchecked CDH_REASON="could not read the daemon's age"; return 0
  }
  CDH_STATE=running
  if [ -z "$always" ] && [ "$CDH_AGE_SECONDS" -lt "$AGMSG_CODEX_DAEMON_AGE_LIMIT_SECONDS" ]; then
    return 0
  fi
  topout="$(top -l 1 -pid "$pid" -stats mem 2>/dev/null | tail -n 1)" || topout=""
  mem="${topout//[[:space:]]/}"
  CDH_FOOTPRINT_MB="$(_agmsg_codex_daemon_mem_mb "$mem")" || {
    CDH_STATE=unchecked CDH_REASON="could not read the daemon's memory footprint"; return 0
  }
  if [ "${CDH_FOOTPRINT_MB:-}" -ge "$AGMSG_CODEX_DAEMON_FOOTPRINT_LIMIT_MB" ] \
     && [ "${CDH_AGE_SECONDS:-}" -ge "$AGMSG_CODEX_DAEMON_AGE_LIMIT_SECONDS" ]; then
    CDH_OVER=1
    sock="$(readlink "$profile/app-server-control/app-server-control.sock" 2>/dev/null)" || sock=""
    if [ -n "$sock" ]; then
      n="$(lsof -a -p "$pid" -U 2>/dev/null | grep -cF "$sock")" || n=0
      [ "$n" -gt 0 ] && CDH_CLIENTS=$(( n - 1 ))
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
