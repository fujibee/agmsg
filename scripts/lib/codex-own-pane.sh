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
#   2. thread -> TUI. Two kinds of evidence, both collected:
#        a. a process whose argv is `codex resume <thread>` (the launcher and
#           the TUI it starts are one);
#        b. the `codex` TUIs (the binary run with no subcommand) whose cwd is
#           the thread's cwd and whose start time is within
#           AGMSG_CODEX_START_SKEW seconds of the thread's created_at in
#           Codex's state_*.sqlite. A fresh launch creates its thread at start.
#      Exactly one distinct process across both must remain. Neither kind proves
#      the TUI STILL holds the thread (a `/clear` moves it to a new thread and
#      leaves the argv behind), so two candidates are never resolved by picking
#      one: more than one -> unknown. A single stale candidate cannot be told
#      from a live one (there is no TUI -> thread link to read); a remembered
#      pane is therefore dropped after AGMSG_CODEX_PANE_TTL and the scan repeated.
#   3. TUI -> pane: that TUI's own HERDR_* / TMUX* environment.
#
# Anything that does not settle to exactly one TUI is "unknown": the caller
# gets no pane rather than the daemon starter's. This file only decides; the
# terminal drivers still turn the environment it returns into an id.
#
# SECRETS. A TUI's environment is the user's whole shell environment. No shell
# variable in this file ever holds a process's full command line or environment:
# the lines of `ps` are filtered by `awk` inside a pipeline, and only the five
# terminal variables (or pids/seconds) come out. So `bash -x` has nothing to
# print (tests/test_codex_own_pane.bats runs it with sentinels to prove that).
#
# Output of agmsg_codex_own_pane (stdout, always exit 0):
#   (empty)                  the environment is believable (not a Codex seat,
#                            not under the shared daemon, or no terminal env)
#   env\nKEY=VALUE...        use exactly these terminal variables instead
#   unknown\t<reason>        the pane cannot be proven; write nothing for it

[ -n "${_AGMSG_CODEX_OWN_PANE_SH:-}" ] && return 0
_AGMSG_CODEX_OWN_PANE_SH=1

: "${AGMSG_CODEX_START_SKEW:=3}"      # seconds between TUI start and thread created_at
: "${AGMSG_CODEX_TRUSTED_TTL:=300}"   # how long "env is believable" is remembered
: "${AGMSG_CODEX_PANE_TTL:=300}"      # how long a proven pane is remembered
: "${AGMSG_CODEX_UNKNOWN_TTL:=15}"    # how long "cannot prove it" is remembered

# Is this process under a `--managed-daemon` app-server?
#   0  yes        1  no (the walk reached the top of the tree)
#   2  cannot tell (ps failed, the process vanished, or 16 hops were not enough)
# "Cannot tell" is never folded into "no": that would trust the daemon starter's
# pane on a transient failure. Only Darwin and Linux have the `ps` this relies
# on; elsewhere (Windows) the environment stays in charge as before.
_agmsg_cop_under_managed_daemon() {
  local pid=$$ hop=0 out ppid flag
  if [ -z "${_AGMSG_COP_PLATFORM:-}" ]; then
    _AGMSG_COP_PLATFORM="$(uname -s 2>/dev/null)" || _AGMSG_COP_PLATFORM=other
  fi
  case "$_AGMSG_COP_PLATFORM" in Darwin|Linux) ;; *) return 1 ;; esac
  while [ "$hop" -lt 16 ]; do
    out="$(ps -o ppid=,command= -p "$pid" 2>/dev/null \
      | awk 'NR==1 { print $1, (index($0, "--managed-daemon") ? "D" : "-") }')"
    [ -n "$out" ] || return 2
    ppid="${out% *}"; flag="${out#* }"
    [ "$flag" = D ] && return 0
    case "$ppid" in ''|*[!0-9]*) return 2 ;; esac
    [ "$ppid" -gt 1 ] || return 1
    pid="$ppid"; hop=$((hop + 1))
  done
  return 2
}

# KEY=VALUE lines for the five terminal variables in <pid>'s environment, and
# nothing else. The environment never reaches a shell variable.
_agmsg_cop_env_of() {   # <pid>
  ps eww -p "$1" -o command= 2>/dev/null | awk '
    BEGIN { n = split("HERDR_ENV HERDR_SOCKET_PATH HERDR_PANE_ID TMUX TMUX_PANE", k, " ")
            for (i = 1; i <= n; i++) want[k[i]] = 1 }
    { for (i = 1; i <= NF; i++) {
        p = index($i, "=")
        if (p > 1 && substr($i, 1, p - 1) in want) val[substr($i, 1, p - 1)] = substr($i, p + 1) } }
    END { for (i = 1; i <= n; i++) if (k[i] in val) print k[i] "=" val[k[i]] }'
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

# <kind> <thread> [pid lstart reason], then KEY=VALUE lines on stdin.
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

# One pass over the process table. Prints only numbers:
#   R <pid> <ppid>      argv is `codex resume <thread>`
#   T <pid> <seconds>   the codex binary run with no subcommand, running <seconds>
_agmsg_cop_scan() {   # <thread>
  ps -axo pid=,ppid=,etime=,command= 2>/dev/null | awk -v t="$1" '
    function secs(e,   d, a, k, p, i, s) {
      d = 0
      if (e ~ /-/) { split(e, a, "-"); d = a[1]; e = a[2] }
      k = split(e, p, ":"); s = 0
      for (i = 1; i <= k; i++) s = s * 60 + p[i]
      return d * 86400 + s }
    { cmd = $4; for (i = 5; i <= NF; i++) cmd = cmd " " $i
      n = split(cmd, w, " ")
      if (n >= 3 && w[n] == t && w[n-1] == "resume" && w[n-2] ~ /(^|\/)codex$/) print "R", $1, $2
      else if (NF == 4 && $4 ~ /(^|\/)codex$/) print "T", $1, secs($3) }'
}

# A remembered pane must not outlive the "exactly one candidate" rule: another
# process started with `codex resume <thread>` since the pane was proven makes
# two candidates. One pgrep answers it (no match: no other resume exists, the
# common case for a fresh launch); only when something else matches is its
# relation to the remembered pid read (its parent, one ps; its children, one pgrep). The remembered pid's own launcher/TUI
# pair is not "another".
#   0  no other process: the remembered pane stands
#   1  another one exists (or pgrep is not installed): drop it and scan again
#   2  the check itself failed: neither "none" nor "some" is known
# pgrep exits 1 for "no match", which is an answer; any other failure (2, 3, 127)
# is not, and is never read as "no match".
_agmsg_cop_no_other_resume() {   # <thread> <remembered pid>
  local out rc=0 others="" p parent kids
  command -v pgrep >/dev/null 2>&1 || return 1
  out="$(pgrep -f "codex resume $1" 2>/dev/null)" || rc=$?
  [ "$rc" -le 1 ] || return 2
  for p in $out; do [ "$p" = "$2" ] || others="$others $p"; done
  [ -n "$others" ] || return 0
  rc=0; parent="$(ps -o ppid= -p "$2" 2>/dev/null)" || rc=$?
  parent="${parent//[[:space:]]/}"
  { [ "$rc" -eq 0 ] && [ -n "$parent" ]; } || return 2
  rc=0; kids="$(pgrep -P "$2" 2>/dev/null)" || rc=$?
  [ "$rc" -le 1 ] || return 2
  kids=" ${kids//$'\n'/ } "
  for p in $others; do
    [ "$p" = "$parent" ] && continue
    case "$kids" in *" $p "*) continue ;; esac
    return 1
  done
  return 0
}

# thread -> the one TUI pid. Prints "ok <pid>" or "no <reason>"; always returns 0
# (it runs in a command substitution, so a variable could not carry the reason).
_agmsg_cop_find_tui() {   # <thread> <thread-cwd> <created_at>
  local tcwd="$2" created="$3" scan now kind a b c leaves p pids="" count=0 only=""
  now="$(date +%s)"
  scan="$(_agmsg_cop_scan "$1")"
  [ -n "$scan" ] || { echo "no no_codex_process_listed"; return 0; }
  # a. resume argv; a match whose parent is also a match is the launcher, dropped.
  leaves="$(printf '%s\n' "$scan" | awk '$1 == "R" { p[$2] = 1; q[$3] = 1 } END { for (k in p) if (!(k in q)) print k }')"
  for p in $leaves; do pids="$pids $p"; done
  # b. started at the thread's creation, in the thread's cwd.
  while read -r kind a b; do
    [ "$kind" = T ] || continue
    [ "$((now - b - created))" -le "$AGMSG_CODEX_START_SKEW" ] \
      && [ "$((created - (now - b)))" -le "$AGMSG_CODEX_START_SKEW" ] || continue
    c="$(_agmsg_cop_cwd_of "$a")" || continue
    [ "$(_agmsg_cop_real "$c")" = "$(_agmsg_cop_real "$tcwd")" ] || continue
    pids="$pids $a"
  done <<EOF
$scan
EOF
  for p in $(printf '%s\n' $pids | sort -u); do count=$((count + 1)); only="$p"; done
  case "$count" in
    1) echo "ok $only" ;;
    0) echo "no no_codex_tui_holds_this_thread" ;;
    *) echo "no several_codex_tuis_may_hold_this_thread" ;;
  esac
}

agmsg_codex_own_pane() {
  local tid="${CODEX_THREAD_ID:-}" f kind ts pid lstart reason now cur env found rc
  [ -n "$tid" ] || return 0
  [ -n "${HERDR_ENV:-}${TMUX:-}${TMUX_PANE:-}${HERDR_PANE_ID:-}" ] || return 0
  case "$tid" in *[!A-Za-z0-9-]*) return 0 ;; esac

  if f="$(_agmsg_cop_cache "$tid")" && [ -f "$f" ]; then
    kind=""
    IFS='|' read -r kind ts pid lstart reason <"$f" || kind=""
    now="$(date +%s)"
    case "$kind" in
      trusted) [ "$((now - ts))" -lt "$AGMSG_CODEX_TRUSTED_TTL" ] && return 0 ;;
      unknown) [ "$((now - ts))" -lt "$AGMSG_CODEX_UNKNOWN_TTL" ] \
                 && { printf 'unknown\t%s\n' "$reason"; return 0; } ;;
      pane)
        # The pid still being that process proves it is alive, not that it still
        # holds this thread; hence the TTL, after which the scan is repeated.
        if [ "$((now - ts))" -lt "$AGMSG_CODEX_PANE_TTL" ]; then
          cur="$(ps -o lstart= -p "$pid" 2>/dev/null)" || cur=""
          if [ -n "$cur" ] && [ "$cur" = "$lstart" ]; then
            rc=0; _agmsg_cop_no_other_resume "$tid" "$pid" || rc=$?
            case "$rc" in
              0) printf 'env\n'
                 { IFS= read -r _; while IFS= read -r _l; do printf '%s\n' "$_l"; done; } <"$f"
                 return 0 ;;
              2) reason="cannot_check_for_another_resume_of_this_thread"
                 printf '' | _agmsg_cop_remember unknown "$tid" "" "" "$reason"
                 printf 'unknown\t%s\n' "$reason"; return 0 ;;
            esac
          fi
        fi ;;
    esac
  fi

  rc=0; _agmsg_cop_under_managed_daemon || rc=$?
  case "$rc" in
    0) ;;
    1) printf '' | _agmsg_cop_remember trusted "$tid"; return 0 ;;
    *) # Could not tell: that is not "no". Trusting the environment here would
       # write the daemon starter's pane on a transient ps failure.
       reason="cannot_tell_whether_under_shared_daemon"
       printf '' | _agmsg_cop_remember unknown "$tid" "" "" "$reason"
       printf 'unknown\t%s\n' "$reason"; return 0 ;;
  esac

  local db row tcwd created
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
  if [ -z "$reason" ] && [ -n "$created" ]; then
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
