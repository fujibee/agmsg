#!/usr/bin/env bash
# grok-own-pane.sh — which pane is THIS grok session in, when the environment
# cannot be believed.
#
# With `use_leader = true` the grok TUIs of one GROK_HOME share one `grok agent
# leader` process (the first TUI's child). A session's tool calls and hooks run
# inside that leader, so they inherit the LEADER's environment: HERDR_PANE_ID /
# TMUX_PANE name the pane of the TUI that started the leader, not the pane of the
# session that ran the command. A second grok TUI then records the first one's
# pane as its own (measured: leader HERDR_PANE_ID=w5:p3, the second TUI in w1:p4G).
#
# The session is found from what grok records about it:
#
#   1. GROK_SESSION_ID names this session.
#   2. GROK_HOME/active_sessions.json maps it to the session's own process, the TUI,
#      accepted only when that process's age matches the start time grok recorded
#      (a stale entry whose pid was reused by another process is not trusted).
#   3. TUI -> pane: that process's own HERDR_* / TMUX* environment.
#
# Only a process with a `grok agent leader` among its ancestors takes this path; any
# other process (a TUI's own shell without a leader, another CLI) keeps the
# environment. Anything that does not settle is "unknown": the caller gets no pane
# rather than the leader starter's.
#
# SECRETS. A TUI's environment is the user's whole shell environment. As in
# codex-own-pane.sh, no shell variable here ever holds a process's full command
# line or environment: `ps eww` is filtered by awk inside a pipeline (reused from
# there) and only the five terminal variables come out, so `bash -x` has nothing
# to print.
#
# Output of agmsg_grok_own_pane (stdout, always exit 0):
#   (empty)                  the environment is believable
#   env\nKEY=VALUE...        use exactly these terminal variables instead
#   unknown\t<reason>        the pane cannot be proven; write nothing for it

[ -n "${_AGMSG_GROK_OWN_PANE_SH:-}" ] && return 0
_AGMSG_GROK_OWN_PANE_SH=1

: "${AGMSG_GROK_TRUSTED_TTL:=300}"   # how long "env is believable" is remembered
: "${AGMSG_GROK_PANE_TTL:=300}"      # how long a proven pane is remembered
: "${AGMSG_GROK_UNKNOWN_TTL:=15}"    # how long "cannot prove it" is remembered

_agmsg_gop_load() {   # the helpers it reuses
  local d="${SKILL_DIR:-}"
  [ -r "$d/scripts/lib/codex-own-pane.sh" ] || d="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  declare -F _agmsg_cop_env_of >/dev/null 2>&1 || . "$d/scripts/lib/codex-own-pane.sh" 2>/dev/null || return 1
  declare -F agmsg_grok_active_session_lookup >/dev/null 2>&1 \
    || SCRIPT_DIR="$d/scripts" . "$d/scripts/internal/grok-session-witness.sh" 2>/dev/null || return 1
}

# Does this process sit under `grok agent leader`?
#   0  yes   1  no (the walk reached the top)   2  cannot tell
_agmsg_gop_under_leader() {
  local pid=$$ hop=0 out ppid flag
  case "$(uname -s 2>/dev/null)" in Darwin|Linux) ;; *) return 1 ;; esac
  while [ "$hop" -lt 16 ]; do
    out="$(ps -o ppid=,command= -p "$pid" 2>/dev/null \
      | awk 'NR==1 { print $1, ($0 ~ /(^|[ \/])grok agent leader( |$)/ ? "L" : "-") }')"
    [ -n "$out" ] || return 2
    ppid="${out% *}"; flag="${out#* }"
    [ "$flag" = L ] && return 0
    case "$ppid" in ''|*[!0-9]*) return 2 ;; esac
    [ "$ppid" -gt 1 ] || return 1
    pid="$ppid"; hop=$((hop + 1))
  done
  return 2
}

# Is <pid> the process active_sessions.json recorded, not a later one that reused the
# number? grok writes the process's start time (pid_start, microseconds since the
# epoch) beside the pid; the process's age (ps etime) must put its start within a few
# seconds of it. Checked against a live grok: pid 69890, etime 3-06:38:36 at epoch
# 1795156925 -> start 1794873809, pid_start 1794873809001420.
#   0 same process   1 a different one (or none)   2 cannot tell
_agmsg_gop_same_process() {   # <pid> <pid_start>
  local et days="" h m s secs start now
  case "$2" in ''|*[!0-9]*) return 2 ;; esac
  et="$(ps -o etime= -p "$1" 2>/dev/null)" || return 1
  et="${et//[[:space:]]/}"
  [ -n "$et" ] || return 1
  case "$et" in *-*) days="${et%%-*}"; et="${et#*-}" ;; esac
  case "$days$et" in *[!0-9:]*) return 2 ;; esac
  IFS=: read -r h m s <<ETIME
$et
ETIME
  if [ -z "$s" ]; then s="$m"; m="$h"; h=0; fi
  secs=$(( 10#${days:-0} * 86400 + 10#${h:-0} * 3600 + 10#${m:-0} * 60 + 10#${s:-0} ))
  now="$(date +%s)"
  start=$((now - secs))
  [ "$((start - $2 / 1000000))" -le "${AGMSG_GROK_START_SKEW:-5}" ] \
    && [ "$(($2 / 1000000 - start))" -le "${AGMSG_GROK_START_SKEW:-5}" ]
}

_agmsg_gop_cache() { [ -n "${SKILL_DIR:-}" ] && printf '%s/run/grok-own-pane.%s\n' "$SKILL_DIR" "$1"; }

# <kind> <session> [pid lstart reason], then KEY=VALUE lines on stdin.
_agmsg_gop_remember() {
  local f tmp
  f="$(_agmsg_gop_cache "$2")" || return 0
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  tmp="$f.$$"
  { printf '%s|%s|%s|%s|%s\n' "$1" "$(date +%s)" "${3:-}" "${4:-}" "${5:-}"; cat; } >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

agmsg_grok_own_pane() {
  local sid="${GROK_SESSION_ID:-}" f kind ts pid lstart reason now cur env rc obj pstart
  [ -n "${HERDR_ENV:-}${TMUX:-}${TMUX_PANE:-}${HERDR_PANE_ID:-}" ] || return 0
  case "$sid" in *[!A-Za-z0-9._-]*) return 0 ;; esac

  # Not a grok process at all (no session id) and not under a leader: nothing to
  # decide. The ancestry walk is what tells a leader's child from anything else.
  if [ -n "$sid" ] && f="$(_agmsg_gop_cache "$sid")" && [ -f "$f" ]; then
    kind=""
    IFS='|' read -r kind ts pid lstart reason <"$f" || kind=""
    now="$(date +%s)"
    case "$kind" in
      trusted) [ "$((now - ts))" -lt "$AGMSG_GROK_TRUSTED_TTL" ] && return 0 ;;
      unknown) [ "$((now - ts))" -lt "$AGMSG_GROK_UNKNOWN_TTL" ] \
                 && { printf 'unknown\t%s\n' "$reason"; return 0; } ;;
      pane)
        if [ "$((now - ts))" -lt "$AGMSG_GROK_PANE_TTL" ]; then
          cur="$(ps -o lstart= -p "$pid" 2>/dev/null)" || cur=""
          if [ -n "$cur" ] && [ "$cur" = "$lstart" ]; then
            printf 'env\n'
            { IFS= read -r _; while IFS= read -r _l; do printf '%s\n' "$_l"; done; } <"$f"
            printf 'AGMSG_COP_TUI_PID=%s\n' "$pid"
            return 0
          fi
        fi ;;
    esac
  fi

  rc=0; _agmsg_gop_under_leader || rc=$?
  case "$rc" in
    0) ;;
    1) [ -n "$sid" ] && printf '' | _agmsg_gop_remember trusted "$sid"; return 0 ;;
    *) reason="cannot_tell_whether_under_grok_leader"
       [ -n "$sid" ] && printf '' | _agmsg_gop_remember unknown "$sid" "" "" "$reason"
       printf 'unknown\t%s\n' "$reason"; return 0 ;;
  esac

  # Under a leader: its environment is the starter's. Find this session's own TUI.
  reason=""
  if [ -z "$sid" ]; then
    reason="grok_session_id_missing"
  elif ! _agmsg_gop_load; then
    reason="grok_session_lookup_unavailable"
  else
    obj="$(agmsg_grok_active_session_lookup "${GROK_HOME:-${HOME:-}/.grok}/active_sessions.json" "$sid" 2>/dev/null)" || obj=""
    pid="$(printf '%s' "$obj" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
    pstart="$(printf '%s' "$obj" | sed -n 's/.*"pid_start"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
    case "$pid" in
      ''|*[!0-9]*) reason="grok_session_not_in_active_sessions" ;;
      *)
        rc=0; _agmsg_gop_same_process "$pid" "$pstart" || rc=$?
        case "$rc" in
          0) env="$(_agmsg_cop_env_of "$pid")" || env="" ;;
          1) env=""; reason="grok_session_process_is_not_the_recorded_one" ;;
          *) env=""; reason="grok_session_start_time_unverifiable" ;;
        esac
        [ -z "$reason" ] || { printf '' | _agmsg_gop_remember unknown "$sid" "" "" "$reason"; printf 'unknown\t%s\n' "$reason"; return 0; }
        case "$env" in
          *HERDR_PANE_ID=*|*TMUX_PANE=*)
            lstart="$(ps -o lstart= -p "$pid" 2>/dev/null)" || lstart=""
            [ -n "$lstart" ] && printf '%s\n' "$env" | _agmsg_gop_remember pane "$sid" "$pid" "$lstart"
            printf 'env\n%s\nAGMSG_COP_TUI_PID=%s\n' "$env" "$pid"
            return 0 ;;
          *) reason="grok_tui_environment_has_no_pane" ;;
        esac ;;
    esac
  fi
  [ -n "$sid" ] && printf '' | _agmsg_gop_remember unknown "$sid" "" "" "$reason"
  printf 'unknown\t%s\n' "$reason"
  return 0
}
