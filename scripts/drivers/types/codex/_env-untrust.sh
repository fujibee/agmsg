#!/usr/bin/env bash
# codex driver hook: is this process's inherited terminal env (HERDR_PANE_ID,
# TMUX/TMUX_PANE, ...) trustworthy, or could it belong to a DIFFERENT seat
# entirely?
#
# #1254: codex-monitor.sh runs one app-server per project and reuses it for
# every later Codex seat in that project. Under `codex --remote`, a seat's
# shell commands run INSIDE that shared app-server process, not inside its
# own TUI client -- so they inherit whatever terminal env the app-server
# itself was born with (the FIRST seat's pane), not their own.
#
# Two ways this session tells it is running inside such a server, tried
# together (a match on either is untrusted):
#
#   (a) AGMSG_CODEX_SHARED_APP_SERVER="<pid>.<start-witness>", stamped on
#       the app-server's OWN command at launch (codex-monitor.sh) -- never
#       exported into codex-monitor.sh's own shell, so nothing it launches
#       BESIDES the app-server (the foreground TUI, the bridge launcher,
#       watch-once/inbox children) inherits it. <pid> is codex-monitor.sh's
#       OWN pid at launch time (the app-server's real parent -- the app-
#       server does not yet have a pid of its own to embed at that point),
#       which stays the app-server's ancestor for as long as either is
#       alive even after the later `exec` into the foreground TUI (`exec`
#       keeps the same pid). Accepted ONLY when <pid> is a genuine LIVE
#       ancestor of THIS shell whose own CURRENT start time still matches
#       <start-witness> -- an inherited-but-leaked copy of the variable
#       (carried by a process that has since moved outside the server,
#       e.g. into its own pane) must NOT count, and does not: that pid
#       will not be found among this shell's own ancestors, or its start
#       time will have moved on.
#   (b) The project's own recorded app-server pidfile (same hash
#       codex-monitor.sh/_app-server.sh use) names a still-live process,
#       confirmed by cmdline (never trust a bare pid -- it could have been
#       recycled), and that pid is among this shell's own ancestors. Tried
#       whether or not (a) found anything, not only when (a)'s marker is
#       absent: if the process that launched the app-server (a)'s marker
#       names has since exited (the seat that started it is long gone, the
#       app-server outlived it and was reused by a later seat), (a) alone
#       would wrongly read as trusted even though this shell is still
#       genuinely inside that same live, reused app-server.
#
# Prints a reason on stdout; rc 0 = untrusted (do not use the inherited
# terminal env), rc 1 = trusted (this process's env is genuinely its own),
# rc 2 = INDETERMINATE. rc 2 is never folded into "trusted" here or by the
# core caller (agmsg_terminal_env_untrusted): not being able to tell is not
# the same fact as a clean negative, so EVERY broken observation below is
# rc 2, not rc 1 -- a marker present but malformed, an unreadable or
# malformed pidfile, a failed ppid/cmdline/start-time read, or an ancestry
# walk that runs out of depth budget before reaching pid 1. The two, and
# only two, ways to end up trusted are a genuine ABSENCE (no marker and no
# pidfile recorded for this project at all) and a COMPLETE walk to pid 1
# that never matches either target this session could identify.
#
# Requires (sourced by the caller before this file, per the core dispatcher's
# own contract): compat.sh (compat_get_ppid, compat_get_cmdline). hash.sh
# (agmsg_sha1) is sourced by this file itself, lazily, when the pidfile
# check needs it and nothing has already provided it. The install root for
# the pidfile path is SKILL_DIR when a caller has set it, else resolved
# from this file's own path -- most callers of this hook (where.sh among
# them) never set SKILL_DIR at all.

agmsg_type_env_untrusted() {
  local marker="${AGMSG_CODEX_SHARED_APP_SERVER:-}" marker_pid="" marker_witness="" malformed=0
  if [ -n "$marker" ]; then
    marker_pid="${marker%%.*}"
    marker_witness="${marker#*.}"
    case "$marker_pid" in ''|*[!0-9]*) malformed=1 ;; esac
    [ -n "$marker_witness" ] || malformed=1
  fi
  if [ "$malformed" -eq 1 ]; then
    printf 'indeterminate: AGMSG_CODEX_SHARED_APP_SERVER is present but not in the expected <pid>.<start-witness> form\n'
    return 2
  fi

  # Resolve the pidfile-recorded target REGARDLESS of whether the marker is
  # also present (see (b) in the header comment for why). indeterminate=1
  # remembers a broken read along this path without giving up on (a): the
  # two are combined into a single verdict only after both have been tried.
  local server_pid="" indeterminate=0 indeterminate_reason=""
  local project pidfile skill_root
  project="$(pwd)"
  if ! declare -F agmsg_sha1 >/dev/null 2>&1; then
    local _hash_lib
    _hash_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" 2>/dev/null && pwd)/hash.sh"
    [ -f "$_hash_lib" ] && . "$_hash_lib" 2>/dev/null
  fi
  # SKILL_DIR, when a caller happens to have set it, is trusted as-is; most
  # callers of this hook (e.g. where.sh) do not, so this falls back to the
  # SAME root the driver/type registries themselves resolve from (this
  # file's own path under scripts/drivers/types/<name>/, three levels below
  # the skill root) -- not a second, competing notion of "the skill root",
  # just not depending on an env var this hook cannot assume is set.
  skill_root="${SKILL_DIR:-}"
  if [ -z "$skill_root" ]; then
    skill_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)"
  fi
  if ! declare -F agmsg_sha1 >/dev/null 2>&1 || [ -z "$skill_root" ]; then
    indeterminate=1
    indeterminate_reason="cannot resolve this project's app-server pidfile (agmsg_sha1 unavailable, or this hook's own install root could not be found)"
  else
    pidfile="$skill_root/run/codex-app-server.$(printf '%s' "$project" | agmsg_sha1 2>/dev/null).pid"
    if [ -f "$pidfile" ]; then
      local raw rc=0
      raw="$(cat "$pidfile" 2>/dev/null)" || rc=$?
      if [ "$rc" -ne 0 ]; then
        indeterminate=1
        indeterminate_reason="this project's app-server pidfile exists but could not be read"
      else
        case "$raw" in
          ''|*[!0-9]*)
            indeterminate=1
            indeterminate_reason="this project's app-server pidfile exists but its content is not a plain pid"
            ;;
          *)
            local cmdline crc=0
            cmdline="$(compat_get_cmdline "$raw" 2>/dev/null)" || crc=$?
            if [ "$crc" -ne 0 ]; then
              indeterminate=1
              indeterminate_reason="could not read cmdline for recorded app-server pid $raw"
            else
              case "$cmdline" in
                *codex*app-server*) server_pid="$raw" ;;
                # Recorded pid is alive but is not (or no longer) a codex
                # app-server: a stale record, not a broken read. Neither
                # trusted nor indeterminate on its own -- just nothing for
                # this path to contribute to the walk below.
              esac
            fi
            ;;
        esac
      fi
    fi
    # pidfile absent entirely: a genuine absence, not a failed read --
    # server_pid stays empty and neither flag is set for this path.
  fi

  if [ -z "$marker_pid" ] && [ -z "$server_pid" ] && [ "$indeterminate" -eq 0 ]; then
    printf 'trusted: no marker and no recorded app-server pid for this project\n'
    return 1
  fi

  local pid="$$" ppid depth=0 max_depth=128
  while :; do
    if [ -n "$marker_pid" ] && [ "$pid" = "$marker_pid" ]; then
      local now_witness wrc=0
      now_witness="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s '[:space:]' '_')" || wrc=$?
      now_witness="${now_witness#_}"; now_witness="${now_witness%_}"
      if [ "$wrc" -ne 0 ] || [ -z "$now_witness" ]; then
        printf 'indeterminate: pid %s matches the marker'"'"'s claimed pid, but its current start time could not be read to confirm it is the same process\n' "$pid"
        return 2
      fi
      if [ "$now_witness" = "$marker_witness" ]; then
        printf 'untrusted: this shell descends from pid %s, confirmed by its own marker and matching start witness\n' "$pid"
        return 0
      fi
      # pid matched but the (successfully read) current start time did
      # not: a DIFFERENT process now happens to hold the marker's claimed
      # pid (reuse), not the one that stamped it. A confirmed non-match,
      # not a broken observation -- keep walking (the pidfile target below
      # may still match further up, or further down a path already passed).
    fi
    if [ -n "$server_pid" ] && [ "$pid" = "$server_pid" ]; then
      printf 'untrusted: this shell descends from pid %s, this project'"'"'s recorded live codex app-server\n' "$pid"
      return 0
    fi
    [ "$pid" != "1" ] || break
    if [ "$depth" -ge "$max_depth" ]; then
      indeterminate=1
      indeterminate_reason="this shell's ancestry is still unresolved after $max_depth levels -- gave up rather than guess"
      break
    fi
    local prc=0
    ppid="$(compat_get_ppid "$pid" 2>/dev/null)" || prc=$?
    if [ "$prc" -ne 0 ]; then
      indeterminate=1
      indeterminate_reason="could not read the parent of pid $pid while walking this shell's ancestry"
      break
    fi
    if [ -z "$ppid" ]; then
      indeterminate=1
      indeterminate_reason="pid $pid reported no parent, short of reaching pid 1"
      break
    fi
    pid="$ppid"
    depth=$((depth + 1))
  done

  if [ "$indeterminate" -eq 1 ]; then
    printf 'indeterminate: %s\n' "$indeterminate_reason"
    return 2
  fi
  printf 'trusted: this shell'"'"'s full ancestry (to pid 1) does not include the app-server this session could identify\n'
  return 1
}
