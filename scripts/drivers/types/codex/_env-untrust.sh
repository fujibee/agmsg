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
# Two ways this session tells it is running inside such a server:
#
#   (a) AGMSG_CODEX_SHARED_APP_SERVER="<pid>.<start-witness>", stamped into
#       the app-server's OWN environment at launch (codex-monitor.sh) --
#       never exported into codex-monitor.sh's own shell, so nothing it
#       launches BESIDES the app-server (the foreground TUI, the bridge
#       launcher, watch-once/inbox children) inherits it. Present here only
#       because THIS shell is a descendant of that specific app-server
#       process. Accepted ONLY when <pid> is a genuine LIVE ancestor of this
#       shell whose own CURRENT start time still matches <start-witness> --
#       an inherited-but-leaked copy of the variable (carried by a process
#       that has since moved outside the server, e.g. into its own pane)
#       must NOT count, and does not: that pid will not be found among this
#       shell's own ancestors, or its start time will have moved on.
#   (b) No marker (a server started before this fix): the project's own
#       recorded app-server pidfile (same hash codex-monitor.sh/
#       _app-server.sh use) names a still-live process, confirmed by cmdline
#       (never trust a bare pid -- it could have been recycled), and that
#       pid is among this shell's own ancestors.
#
# Prints a reason on stdout; rc 0 = untrusted (do not use the inherited
# terminal env), rc 1 = trusted (this process's env is genuinely its own),
# rc 2 = INDETERMINATE (could not walk the ancestry, or could not read a
# pidfile). rc 2 is never folded into "trusted" here or by the core caller
# (agmsg_terminal_env_untrusted): not being able to tell is not the same
# fact as a clean negative.
#
# Requires (sourced by the caller before this file, per the core dispatcher's
# own contract): compat.sh (compat_get_ppid, compat_get_cmdline), hash.sh
# (agmsg_sha1) when method (b) is needed, and SKILL_DIR set.

agmsg_type_env_untrusted() {
  local marker="${AGMSG_CODEX_SHARED_APP_SERVER:-}" marker_pid="" marker_witness=""
  if [ -n "$marker" ]; then
    marker_pid="${marker%%.*}"
    marker_witness="${marker#*.}"
    case "$marker_pid" in ''|*[!0-9]*) marker_pid="" ;; esac
  fi

  local server_pid=""
  if [ -z "$marker_pid" ]; then
    # Method (b): resolve THIS project's recorded app-server pid the same
    # way _app-server.sh's _agmsg_codex_app_server_url does, so the ancestry
    # walk below has something to look for even with no marker present.
    local project pidfile
    project="$(pwd)"
    if declare -F agmsg_sha1 >/dev/null 2>&1 && [ -n "${SKILL_DIR:-}" ]; then
      pidfile="$SKILL_DIR/run/codex-app-server.$(printf '%s' "$project" | agmsg_sha1 2>/dev/null).pid"
      if [ -f "$pidfile" ]; then
        server_pid="$(cat "$pidfile" 2>/dev/null || true)"
        case "$server_pid" in ''|*[!0-9]*) server_pid="" ;; esac
      fi
    fi
    if [ -z "$server_pid" ]; then
      printf 'trusted: no marker and no recorded app-server pid for this project\n'
      return 1
    fi
    local cmdline rc=0
    cmdline="$(compat_get_cmdline "$server_pid" 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'indeterminate: could not read cmdline for recorded app-server pid %s\n' "$server_pid"
      return 2
    fi
    case "$cmdline" in
      *codex*app-server*) : ;;
      *)
        printf 'trusted: recorded app-server pid %s is not (or no longer) a codex app-server\n' "$server_pid"
        return 1
        ;;
    esac
  fi

  local target="${marker_pid:-$server_pid}" pid="$$" ppid depth=0 max_depth=12
  while [ "$depth" -lt "$max_depth" ] && [ -n "$pid" ] && [ "$pid" != "1" ]; do
    if [ "$pid" = "$target" ]; then
      if [ -n "$marker_pid" ]; then
        local now_witness
        now_witness="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s '[:space:]' '_')"
        now_witness="${now_witness#_}"; now_witness="${now_witness%_}"
        if [ -n "$now_witness" ] && [ "$now_witness" = "$marker_witness" ]; then
          printf 'untrusted: this shell is a descendant of app-server pid %s, confirmed by its own marker and matching start witness\n' "$pid"
          return 0
        fi
        # pid matched but the current start time did not: this is a DIFFERENT
        # process that now happens to hold the marker's claimed pid (reuse),
        # not the server that stamped it. Keep walking -- a mismatch here is
        # not proof that no real ancestor exists further up.
      else
        printf 'untrusted: this shell is a descendant of pid %s, this project'"'"'s recorded live codex app-server\n' "$pid"
        return 0
      fi
    fi
    local rc=0
    ppid="$(compat_get_ppid "$pid" 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'indeterminate: could not read the parent of pid %s while walking this shell'"'"'s ancestry\n' "$pid"
      return 2
    fi
    [ -n "$ppid" ] || break
    pid="$ppid"
    depth=$((depth + 1))
  done
  printf 'trusted: no ancestor of this shell (within %s levels) matched the app-server this session could identify\n' "$max_depth"
  return 1
}
