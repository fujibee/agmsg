#!/usr/bin/env bash
# codex-own-pane.sh — which pane is THIS Codex seat in, when the environment
# cannot be believed (#1736, #1112).
#
# Under Codex's shared app-server daemon (`codex app-server --managed-daemon`,
# one per CODEX_HOME) every tool shell and hook is a child of the daemon, and
# the daemon inherited the environment of whichever pane started it first. So
# HERDR_PANE_ID / TMUX_PANE in a seat's tool shell name the daemon's starter,
# not the seat. The Codex TUI process itself still carries its own pane's
# environment (measured, ps eww on every live TUI), and the thread is what ties
# the seat to that TUI:
#
#   1. CODEX_THREAD_ID (set by the daemon per thread) names this seat's thread.
#   2. thread -> TUI, strongest first:
#        a. a process whose argv is `codex resume <thread>` (the seat was
#           started or restarted by resuming);
#        b. else the one TUI (the `codex` binary run with no subcommand) whose
#           cwd is the thread's cwd and whose start time is within
#           AGMSG_CODEX_START_SKEW seconds of the thread's created_at in
#           Codex's state_*.sqlite. A fresh launch creates its thread at start.
#   3. TUI -> pane: that TUI's own HERDR_* / TMUX* environment.
#
# Anything that does not settle to exactly one TUI is "unknown": the caller
# gets no pane rather than the daemon starter's. This file only decides; the
# terminal drivers still turn the environment it returns into an id.
#
# Output of agmsg_codex_own_pane (stdout, always exit 0):
#   (empty)                  the environment is believable (not a Codex seat,
#                            not under the shared daemon, or no terminal env)
#   env\nKEY=VALUE...        use exactly these terminal variables instead
#   unknown\t<reason>        the pane cannot be proven; write nothing for it
#
# Cost: a verdict is remembered per thread in $SKILL_DIR/run/, so the process
# scan is paid once per thread, not per send/inbox. A remembered pane is
# re-checked with one `ps` (the TUI pid still has the start time recorded).

[ -n "${_AGMSG_CODEX_OWN_PANE_SH:-}" ] && return 0
_AGMSG_CODEX_OWN_PANE_SH=1

: "${AGMSG_CODEX_START_SKEW:=3}"      # seconds between TUI start and thread created_at
: "${AGMSG_CODEX_TRUSTED_TTL:=300}"   # how long "env is believable" is remembered
: "${AGMSG_CODEX_UNKNOWN_TTL:=15}"    # how long "cannot prove it" is remembered

_AGMSG_COP_VARS="HERDR_ENV HERDR_SOCKET_PATH HERDR_PANE_ID TMUX TMUX_PANE"

# Is this process a descendant of a `--managed-daemon` app-server? Walks parents
# with one `ps` per hop; any failure (no such ps, Windows) answers "no", which
# leaves the environment in charge exactly as before.
_agmsg_cop_under_managed_daemon() {
  local pid=$$ hop=0 line ppid cmd
  while [ "$hop" -lt 16 ] && [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    line="$(ps -o ppid=,command= -p "$pid" 2>/dev/null)" || return 1
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || return 1
    ppid="${line%%[[:space:]]*}"
    cmd="${line#*[[:space:]]}"
    case "$cmd" in *--managed-daemon*) return 0 ;; esac
    pid="$ppid"; hop=$((hop + 1))
  done
  return 1
}

# KEY=VALUE lines for the terminal variables in <pid>'s environment.
_agmsg_cop_env_of() {   # <pid>
  local line key tok
  line="$(ps eww -p "$1" -o command= 2>/dev/null)" || return 1
  for key in $_AGMSG_COP_VARS; do
    case "$line" in *" $key="*) ;; *) continue ;; esac
    tok="${line##* "$key"=}"
    printf '%s=%s\n' "$key" "${tok%% *}"
  done
}

_agmsg_cop_cwd_of() {   # <pid>
  local c=""
  if [ -d "/proc/$1" ]; then
    c="$(readlink "/proc/$1/cwd" 2>/dev/null)" || c=""
  elif command -v lsof >/dev/null 2>&1; then
    c="$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)" || c=""
  fi
  [ -n "$c" ] || return 1
  printf '%s\n' "$c"
}

_agmsg_cop_real() { ( cd -P "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"; }

# Codex's thread table: newest state_<n>.sqlite under CODEX_HOME.
_agmsg_cop_state_db() {
  local home="${CODEX_HOME:-${HOME:-}/.codex}" f n best="" bestn=-1
  for f in "$home"/state_[0-9]*.sqlite; do
    [ -f "$f" ] || continue
    n="${f##*/state_}"; n="${n%.sqlite}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt "$bestn" ] && { best="$f"; bestn="$n"; }
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

_agmsg_cop_cache() {   # <thread>
  [ -n "${SKILL_DIR:-}" ] || return 1
  printf '%s/run/codex-own-pane.%s\n' "$SKILL_DIR" "$1"
}

# <kind> <thread> [pid lstart reason] then env lines on stdin for kind=pane.
_agmsg_cop_remember() {
  local f tmp
  f="$(_agmsg_cop_cache "$2")" || return 0
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  tmp="$f.$$"
  {
    printf '%s|%s|%s|%s|%s\n' "$1" "$(date +%s)" "${3:-}" "${4:-}" "${5:-}"
    cat
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# Process scan -> candidate. Prints "ok <pid>" or "no <reason>"; always returns 0
# (it runs in a command substitution, so a variable could not carry the reason).
_agmsg_cop_find_tui() {   # <thread> <thread-cwd> <created_at>
  local tid="$1" tcwd="$2" created="$3" now rows resume n=0 pid="" secs start c matches=0
  now="$(date +%s)"
  rows="$(ps -axo pid=,ppid=,etime=,command= 2>/dev/null)" || rows=""
  [ -n "$rows" ] || { echo "no process_list_unavailable"; return 0; }
  # a. `codex resume <thread>` in argv.
  resume="$(printf '%s\n' "$rows" | awk -v t="$tid" '
    { cmd=$4; for (i=5;i<=NF;i++) cmd=cmd " " $i
      n=split(cmd, w, " ")
      if (n>=3 && w[n]==t && w[n-1]=="resume" && w[n-2] ~ /(^|\/)codex$/) print $1, $2 }' \
    | awk '{ p[$1]=1; q[$2]=1 } END { for (k in p) if (!(k in q)) print k }')"
  # The npm launcher (node ... codex resume <id>) and the TUI it starts carry the
  # same argv: they are one seat, so a match whose parent is also a match is dropped.
  if [ -n "$resume" ]; then
    n="$(printf '%s\n' "$resume" | wc -l | tr -d ' ')"
    if [ "$n" -eq 1 ]; then echo "ok $resume"; else echo "no several_processes_resume_this_thread"; fi
    return 0
  fi
  # b. the TUI started at the thread's creation, in the thread's cwd.
  while read -r pid secs; do
    [ -n "$pid" ] || continue
    start=$((now - secs))
    [ "$((start - created))" -le "$AGMSG_CODEX_START_SKEW" ] \
      && [ "$((created - start))" -le "$AGMSG_CODEX_START_SKEW" ] || continue
    c="$(_agmsg_cop_cwd_of "$pid")" || continue
    [ "$(_agmsg_cop_real "$c")" = "$(_agmsg_cop_real "$tcwd")" ] || continue
    matches=$((matches + 1)); n="$pid"
  done <<EOF
$(printf '%s\n' "$rows" | awk '
  # the codex binary run with no subcommand: exactly one word, basename codex
  NF==4 && $4 ~ /(^|\/)codex$/ {
    e=$3; d=0; if (e ~ /-/) { split(e, a, "-"); d=a[1]; e=a[2] }
    k=split(e, p, ":"); s=0
    for (i=1;i<=k;i++) s=s*60+p[i]
    print $1, d*86400+s }')
EOF
  case "$matches" in
    1) echo "ok $n" ;;
    0) echo "no no_codex_tui_started_with_this_thread" ;;
    *) echo "no several_codex_tuis_match_this_thread" ;;
  esac
}

agmsg_codex_own_pane() {
  local tid="${CODEX_THREAD_ID:-}" f kind ts pid lstart reason now cur env
  [ -n "$tid" ] || return 0
  [ -n "${HERDR_ENV:-}${TMUX:-}${TMUX_PANE:-}${HERDR_PANE_ID:-}" ] || return 0
  case "$tid" in *[!A-Za-z0-9-]*) return 0 ;; esac

  if f="$(_agmsg_cop_cache "$tid")" && [ -f "$f" ]; then
    IFS='|' read -r kind ts pid lstart reason <"$f" || kind=""
    now="$(date +%s)"
    case "$kind" in
      trusted) [ "$((now - ts))" -lt "$AGMSG_CODEX_TRUSTED_TTL" ] && return 0 ;;
      unknown) [ "$((now - ts))" -lt "$AGMSG_CODEX_UNKNOWN_TTL" ] \
                 && { printf 'unknown\t%s\n' "$reason"; return 0; } ;;
      pane)
        cur="$(ps -o lstart= -p "$pid" 2>/dev/null)" || cur=""
        if [ -n "$cur" ] && [ "$cur" = "$lstart" ]; then
          printf 'env\n'
          { IFS= read -r _; while IFS= read -r _l; do printf '%s\n' "$_l"; done; } <"$f"
          return 0
        fi ;;
    esac
  fi

  if ! _agmsg_cop_under_managed_daemon; then
    printf '' | _agmsg_cop_remember trusted "$tid"
    return 0
  fi

  local db row tcwd created found
  reason=""
  db="$(_agmsg_cop_state_db)" || db=""
  if [ -z "$db" ] || ! command -v sqlite3 >/dev/null 2>&1; then
    reason="codex_state_db_unreadable"
  else
    # query_only, not -readonly: on the live WAL database `-readonly` cannot open
    # the file at all (measured, "unable to open database file"), while a normal
    # open with query_only set reads it and cannot write.
    row="$(sqlite3 -cmd '.timeout 1000' -separator $'\t' "$db" \
      "pragma query_only=1; select created_at, cwd from threads where id='$tid'" 2>/dev/null)" || row=""
    created="${row%%$'\t'*}"; tcwd="${row#*$'\t'}"
    case "$created" in ''|*[!0-9]*) reason="thread_not_in_codex_state_db"; created="" ;; esac
  fi
  if [ -z "${reason:-}" ] && [ -n "$created" ]; then
    found="$(_agmsg_cop_find_tui "$tid" "$tcwd" "$created")"
    if [ "${found%% *}" = ok ]; then
      pid="${found#ok }"
      env="$(_agmsg_cop_env_of "$pid")" || env=""
      case "$env" in
        *HERDR_PANE_ID=*|*TMUX_PANE=*)
          lstart="$(ps -o lstart= -p "$pid" 2>/dev/null)" || lstart=""
          [ -n "$lstart" ] && printf '%s\n' "$env" | _agmsg_cop_remember pane "$tid" "$pid" "$lstart"
          printf 'env\n%s\n' "$env"
          return 0 ;;
        *) reason="codex_tui_environment_has_no_pane" ;;
      esac
    else
      reason="${found#no }"
    fi
  fi
  printf '' | _agmsg_cop_remember unknown "$tid" "" "" "$reason"
  printf 'unknown\t%s\n' "$reason"
  return 0
}
