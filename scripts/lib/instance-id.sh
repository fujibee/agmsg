#!/usr/bin/env bash
# instance-id.sh — per-process runtime instance identity.
#
# A Claude Code `session_id` is NOT unique across parallel
# `claude --continue` / `--resume` processes (#93): the second process re-fires
# SessionStart with the *original* session_id, so two live processes claim to
# be the same session. Keying watcher/lock state (pidfile, watermark, actas
# owner) on session_id alone makes those two processes collide — most visibly
# the watch.sh "kill the previous holder for this session" logic (#66) turns
# into a mutual kill loop.
#
# We disambiguate by composing the session_id with the enclosing agent process
# pid, which IS unique per live process. The resulting "instance id":
#   - is stable across /clear within one agent process (sid + pid unchanged),
#     so the #66 dedup-on-relaunch still works;
#   - differs between parallel resume processes (different pid), so their
#     pidfile / watermark / actas owner stop colliding.
#
# Token shape:
#   "<session_id>.<pid>"   composite — pid is the enclosing agent process
#   "<session_id>"         bare — fallback when the agent pid can't be resolved
#                          (detached watcher, sandboxed ps, non-agent wrapper)
#
# session_ids are UUIDs / "agmsg-<...>" / "unknown-<pid>" — none contain a '.',
# so "last dot-segment is numeric" unambiguously marks the composite form.
#
# Requires: SKILL_DIR set. agmsg_instance_id / agmsg_normalize_instance_id
# additionally require resolve-project.sh sourced (for agmsg_agent_pid);
# agmsg_instance_alive and the pure helpers do not.

# Guard against double-source (these are sourced transitively via actas-lock.sh
# and directly by entry-point scripts).
[ -n "${_AGMSG_INSTANCE_ID_SH:-}" ] && return 0
_AGMSG_INSTANCE_ID_SH=1

# Cross-platform pid liveness check, and the ONLY one any shipped script should
# use. A bare `kill -0 "$pid" 2>/dev/null` is not a liveness check: it answers
# "can I signal this", and the two differ exactly where it matters.
#
# Git Bash's kill(1) only sees MSYS2/Cygwin PIDs; native Windows processes
# (Claude Code, etc.) are invisible to it, so kill -0 always returns false for
# them (#134). On Windows we fall back to tasklist.exe, which queries the native
# process table.
#
# Everywhere else, saying "dead" requires kill(2) and ps to agree. A failed
# `kill -0` is ESRCH (dead) or EPERM (alive, but not signalable by us — a
# sandbox does exactly this). Reading only the exit status reports a live
# process as gone, which is how a running watcher or bridge gets printed as a
# stale pidfile, how a live lock owner gets its lock reclaimed out from under
# it, and how a second app-server gets started beside the first.
# True iff <value> is a plain positive decimal pid, i.e. a value that names one
# process when handed to kill(1).
#
# Digits-only is NOT enough. `kill -0 0` does not ask about pid 0 — 0 means "the
# caller's own process group" — so it succeeds, and a caller that then runs
# `kill "$pid"` TERMs the whole group, itself included. A corrupt or hostile
# pidfile holding 0 is all it takes. A leading zero is rejected for a related
# reason: nothing here writes one, and kill(1) may read it as octal, so it names
# an unpredictable process.
#
# Patterns only, never `$(( ))`: arithmetic evaluation runs its argument.
#
# Split out from _agmsg_pid_alive so a caller that kills a recorded pid WITHOUT
# asking about liveness first can still refuse the values that do not name one
# process.
# A ceiling may be passed as $2 to override the platform's. Which one is right is
# a property of what the value will be USED for, not of the host -- see the call
# in _agmsg_pid_alive_local, which hands the value to kill(1) even on Windows.
_agmsg_pid_valid() {
  local pid="${1:-}" max="${2:-}"
  case "$pid" in ''|*[!0-9]*|0*) return 1 ;; esac
  if [ -n "$max" ]; then
    [ "${#pid}" -le 10 ] || return 1
    if [ "${#pid}" -eq 10 ] && [ "$pid" \> "$max" ]; then return 1; fi
    return 0
  fi
  max=2147483647
  # The upper bound is the platform's, not one number. A Windows process id is a
  # DWORD, and the liveness path there queries the native process table via
  # tasklist rather than kill(1)'s signed pid_t — applying the POSIX bound to it
  # would call a legitimate native pid dead and its live watcher stale.
  case "${MSYSTEM:-}" in MINGW*|MSYS*|CLANGARM*) max=4294967295 ;; esac
  # And it has to fit whichever of those the platform uses. The POSIX ceiling is
  # what makes the rest of this library safe: past INT32_MAX, kill(1) rejects the
  # ARGUMENT ("not a pid or valid job spec") rather than reporting ESRCH — and
  # _agmsg_pid_alive reads every non-ESRCH failure as alive, so an oversized
  # value in a pidfile would read as alive forever: its lock never reclaimed, its
  # bridge never restarted, its status line permanently wrong. Bounding the input
  # is what keeps "not ESRCH" meaning "EPERM". The Windows ceiling is a plain
  # range check on the value tasklist will be asked about; nothing there parses
  # it as a signal target.
  #
  # Length is a builtin, and the digits are already known to have no leading
  # zero, so at equal length a STRING compare is the numeric one. No `$(( ))`
  # and no `-gt` on the untrusted value: both evaluate what they are given.
  [ "${#pid}" -le 10 ] || return 1
  if [ "${#pid}" -eq 10 ] && [ "$pid" \> "$max" ]; then return 1; fi
  return 0
}

# Liveness for a pid THIS codebase minted: $! or $$ in one of these shells, or
# read back from a pidfile one of them wrote. A pidfile does not launder the pid
# space -- the number in it is still whatever the shell that wrote it was given.
#
# Under Git Bash such a pid is numbered in the MSYS space, which `tasklist` does
# not report, so the Windows branch in _agmsg_pid_alive must not run for one:
# asking tasklist about an MSYS pid answers "dead" for a process that is running,
# which is how every Windows codex launch lost its bridge (#567).
#
# The EPERM reading and the ps cross-check are the same as _agmsg_pid_alive's --
# a pid we minted is still a pid a sandbox may refuse to let us signal (#505).
_agmsg_pid_alive_local() {
  local pid="$1" err stat
  # The POSIX ceiling, explicitly, whatever the host. _agmsg_pid_valid widens to
  # the DWORD range when MSYSTEM is set, which is right for a number tasklist
  # will be asked about and wrong for one kill(1) will parse: past INT32_MAX kill
  # rejects the ARGUMENT rather than reporting ESRCH, and everything below that
  # is not ESRCH reads as alive. Inheriting the wide ceiling here would put an
  # oversized pidfile value back to alive forever -- the shape #505 closed.
  _agmsg_pid_valid "$pid" 2147483647 || return 1
  # Fast path, and the common answer: the builtin, no fork. Callers poll this in
  # loops whose whole point is to be fork-free (#466), so the alive case must
  # not cost a subshell.
  kill -0 "$pid" 2>/dev/null && return 0
  # Only now pay for the error text. `export LC_ALL=C` (not a bare prefix, which
  # misses the builtin on bash 3.2) forces English for the match below.
  err="$(export LC_ALL=C; kill -0 "$pid" 2>&1)" && return 0
  case "$err" in
    *[Nn]'o such process'*) ;;
    *) return 0 ;;   # EPERM and anything unrecognised mean "assume alive"
  esac
  # kill(2) says gone. ps does not depend on signalling permission at all, so
  # requiring it to agree is what keeps a sandbox from turning "cannot signal"
  # into "not running".
  stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -n "$stat" ] || return 1
  case "$stat" in Z*) return 1 ;; esac   # exited, just not reaped yet
  return 0
}

# Liveness for a pid that came from OUTSIDE these shells -- reached by walking
# ancestors until the walk leaves the MSYS subsystem, so under Git Bash the
# number is a Windows pid and kill(1) there cannot see it at all (#134).
#
# Which of the two applies is decided by where the pid was minted, not by whether
# it arrived through a pidfile. For anything $! or $$ produced, and anything read
# back from a pidfile one of these shells wrote, use _agmsg_pid_alive_local.
_agmsg_pid_alive() {
  local pid="$1"
  _agmsg_pid_valid "$pid" || return 1
  case "${MSYSTEM:-}" in
    MINGW*|MSYS*|CLANGARM*)
      MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $pid" 2>/dev/null | grep -q "$pid"
      return $?
      ;;
  esac
  _agmsg_pid_alive_local "$pid"
}

# Compose from an explicit pid. Bare sid when pid is empty/non-numeric.
agmsg_instance_id_from_pid() {
  local sid="$1" pid="$2"
  case "$pid" in
    ''|*[!0-9]*) printf '%s' "$sid" ;;
    *)           printf '%s.%s' "$sid" "$pid" ;;
  esac
}

# True iff <token> is composite "<sid>.<pid>": a non-empty prefix, a '.', and
# an all-digits suffix.
agmsg_instance_is_composite() {
  local token="$1"
  case "$token" in
    *.*) ;;
    *) return 1 ;;
  esac
  local pid="${token##*.}" prefix="${token%.*}"
  [ -n "$prefix" ] || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Extract the bare session_id from an instance id <token>: strips the trailing
# ".<pid>" of a composite "<sid>.<pid>"; a bare "<sid>" is returned unchanged.
# The bare sid is the identity that is STABLE across resume generations (the
# enclosing pid changes on each resume, the session_id does not), so role→
# session records key on it rather than on the composite instance id — see
# role-session.sh.
agmsg_instance_bare_sid() {
  local token="$1"
  if agmsg_instance_is_composite "$token"; then
    printf '%s' "${token%.*}"
  else
    printf '%s' "$token"
  fi
}

# Derive an instance id for <session_id> from the enclosing agent <type>.
# Resolves the agent pid via agmsg_agent_pid; on failure falls back to the bare
# session_id and emits a one-line stderr warning. The fallback is a known
# degraded mode: if one entry point (e.g. the Bash tool path) resolves the pid
# while another (e.g. the Monitor persistent command) cannot, their tokens
# diverge — the warning makes that split traceable in logs.
agmsg_instance_id() {
  local sid="$1" type="$2" pid=""
  pid="$(agmsg_agent_pid "$type" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    printf 'agmsg: instance-id falling back to bare session_id (agent pid unresolved for type=%s); parallel --continue/--resume isolation is degraded\n' "$type" >&2
    printf '%s' "$sid"
    return 0
  fi
  agmsg_instance_id_from_pid "$sid" "$pid"
}

# Idempotent normalize: a token already in composite form is returned as-is; a
# bare session_id is upgraded via agmsg_instance_id. This is the single entry
# point every script calls on its raw first/owner argument, so a script handed
# a pre-computed instance id (hook/monitor path) does not re-derive, while a
# script handed a bare session_id (template path) self-derives.
agmsg_normalize_instance_id() {
  local token="$1" type="$2"
  if agmsg_instance_is_composite "$token"; then
    printf '%s' "$token"
    return 0
  fi
  agmsg_instance_id "$token" "$type"
}

# Walk up the ppid chain from <pid> (default: this shell) looking for an ancestor
# whose command basename is exactly "grok". Prints that pid and returns 0; returns
# 1 if none is found within a small depth bound. Grok Build's `monitor` tool runs
# the watcher as a descendant of the grok process, so the grok session that owns a
# watcher is reliably one of its ancestors — when that grok exits, the watcher is
# orphaned (reparented to init) and the walk no longer finds it.
agmsg_grok_ancestor_pid() {
  local pid="${1:-$$}" depth=0 ppid comm
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ] && [ "$depth" -lt 12 ]; do
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$ppid" ] || return 1
    comm=$(ps -o comm= -p "$ppid" 2>/dev/null || true)
    if [ "${comm##*/}" = grok ]; then
      printf '%s' "$ppid"
      return 0
    fi
    pid="$ppid"
    depth=$((depth + 1))
  done
  return 1
}

# Newest UUID-form session id under a grok project session dir. Grok names each
# session dir with a UUID; the most-recently-modified one is the active session
# for the live grok process. Prints the id and returns 0; 1 if the dir has none.
agmsg_grok_newest_session_id() {
  local sess_dir="$1" d name
  [ -d "$sess_dir" ] || return 1
  for d in $(ls -1dt "$sess_dir"/*/ 2>/dev/null); do
    name=${d%/}; name=${name##*/}
    case "$name" in
      [0-9a-fA-F]*-[0-9a-fA-F]*-*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# Resolve a stable, session-bound instance id for a grok-build watcher.
#
# Grok Build's `monitor` tool launches the watcher in a shell where
# GROK_SESSION_ID is unset, so neither the env var nor the agmsg_agent_pid ppid
# walk (which keys on the claude/codex agent binaries) yields grok's session. The
# watcher would otherwise key on a throwaway id (a fresh one per relaunch → a
# fresh watermark → replayed/"start from now" gaps, and — being bare, not
# composite — NO liveness gating, so it lingers forever after grok exits, #245).
# Bind to a composite "<session_id>.<grok_pid>" instead: STABLE across watcher
# relaunches (same session → same watermark/pidfile) and liveness-gated on the
# grok pid (the watcher self-exits once grok dies). Two cases:
#   1. `grok --resume <id>` — the id is in argv; pair it with that grok pid.
#   2. fresh `grok` (no --resume, no id in argv) — the watcher is a descendant of
#      the grok that launched it; pair that ancestor grok pid with the project's
#      newest session id.
# Prints "<id>.<pid>" and returns 0 on success; 1 if no live grok is found for
# this project (caller then falls back to a throwaway id so the watcher still
# starts).
agmsg_grok_instance_id() {
  local project="$1" enc sess_dir gp gargs gid grok_pid
  [ -n "$project" ] || return 1
  # grok url-encodes the project path (only '/' → '%2F') for its session dir.
  enc=$(printf '%s' "$project" | sed 's#/#%2F#g')
  sess_dir="$HOME/.grok/sessions/$enc"
  [ -d "$sess_dir" ] || return 1

  # 1) Primary: bind to the grok process that actually launched THIS watcher (its
  #    ancestor). This is correct even when several grok sessions share the same
  #    project — a plain `pgrep -x grok` scan could otherwise bind watcher B to
  #    watcher A's grok, colliding their pidfile/watermark and liveness. If the
  #    ancestor grok was started with `--resume <id>`, key on that id; otherwise
  #    (a fresh grok) key on the project's newest session id.
  grok_pid=$(agmsg_grok_ancestor_pid 2>/dev/null || true)
  if [ -n "$grok_pid" ]; then
    gargs=$(ps -o args= -p "$grok_pid" 2>/dev/null || true)
    gid=""
    case "$gargs" in
      *--resume*) gid=$(printf '%s' "$gargs" | sed -n 's/.*--resume[ =]*\([0-9A-Za-z][0-9A-Za-z-]*\).*/\1/p') ;;
    esac
    # A resume id must belong to this project's session dir; else fall back to
    # the newest session id under it.
    [ -n "$gid" ] && [ ! -e "$sess_dir/$gid" ] && gid=""
    [ -n "$gid" ] || gid=$(agmsg_grok_newest_session_id "$sess_dir" 2>/dev/null || true)
    if [ -n "$gid" ]; then
      printf '%s.%s' "$gid" "$grok_pid"
      return 0
    fi
  fi

  # 2) Fallback: the ancestor grok could not be resolved (a detached watcher with
  #    no grok in its process tree). Best-effort — find any live `grok --resume
  #    <id>` whose <id> is in this project's dir.
  for gp in $(pgrep -x grok 2>/dev/null || true); do
    gargs=$(ps -o args= -p "$gp" 2>/dev/null || true)
    case "$gargs" in *--resume*) ;; *) continue ;; esac
    gid=$(printf '%s' "$gargs" | sed -n 's/.*--resume[ =]*\([0-9A-Za-z][0-9A-Za-z-]*\).*/\1/p')
    [ -n "$gid" ] || continue
    if [ -e "$sess_dir/$gid" ]; then
      printf '%s.%s' "$gid" "$gp"
      return 0
    fi
  done

  return 1
}

# Reap orphaned grok-build watchers for <project>: live watch.sh processes whose
# launching grok has exited (no live grok ancestor — see agmsg_grok_ancestor_pid).
# A bare-id watcher from before the composite-binding fix never self-exits when
# its grok dies (#245), so a fresh grok watcher sweeps those leftovers on startup.
# Specific-PID kill ONLY — never a pattern kill (`pkill -f watch.sh` once wiped
# every live watcher across all sessions). Skips <self_pid> and any watcher that
# still has a live grok ancestor (its grok is alive → not an orphan).
# True iff <args> is an actual `<shell> <path>/watch.sh ... grok-build ...`
# invocation for <project> — NOT merely a process whose command line mentions
# those strings (e.g. a shell running `grep watch.sh ... grok-build`, which a
# loose substring match would wrongly flag and kill). Confirms watch.sh is the
# executed script (argv[0] or argv[1] basename) and grok-build / the project are
# positional args, not text inside a `-c` wrapper.
#
# Word-splits the ps args string, so a project path containing whitespace will
# not match and its orphan watcher would simply be left alone (fail-closed — the
# bias is toward never killing the wrong process, never toward a stray kill).
agmsg_args_is_grok_watcher() {
  local args="$1" project="${2:-}" a1 a2 saw_type=0 saw_proj=0 w
  [ -n "$args" ] || return 1
  set -f
  # shellcheck disable=SC2086
  set -- $args
  set +f
  # Guard every positional access: callers run under `set -u`, and ps lists
  # kernel/system processes with empty args, so $1/$2 may be unset here.
  [ "$#" -ge 1 ] || return 1
  a1="${1##*/}"
  a2=""; [ "$#" -ge 2 ] && a2="${2##*/}"
  # watch.sh must be the program: `watch.sh ...` or `<shell> watch.sh ...`.
  [ "$a1" = "watch.sh" ] || [ "$a2" = "watch.sh" ] || return 1
  for w in "$@"; do
    [ "$w" = "grok-build" ] && saw_type=1
    [ "$w" = "$project" ] && saw_proj=1
  done
  [ "$saw_type" = 1 ] && [ "$saw_proj" = 1 ]
}

agmsg_reap_orphan_grok_watchers() {
  local project="$1" self="${2:-$$}" pid args
  [ -n "$project" ] || return 0
  command -v ps >/dev/null 2>&1 || return 0
  # Default IFS so `read` splits the leading pid column off the rest as args; an
  # empty IFS would put the whole line in $pid and match nothing.
  while read -r pid args; do
    _agmsg_pid_valid "$pid" || continue
    [ -n "${args:-}" ] || continue
    [ "$pid" = "$self" ] && continue
    agmsg_args_is_grok_watcher "$args" "$project" || continue
    # A live grok ancestor means the watcher is still owned by a running grok.
    agmsg_grok_ancestor_pid "$pid" >/dev/null 2>&1 && continue
    kill "$pid" 2>/dev/null || true
  done <<EOF
$(ps -eo pid=,args= 2>/dev/null)
EOF
}

# True iff <token> identifies a still-live instance.
#   composite "<sid>.<pid>" → the embedded pid is alive (kill -0), AND, when a
#                            cc-instance.<pid> record exists for that pid, its
#                            content still names this exact token. A shared pid
#                            (the Claude Code 2.1.x daemon, #349) can outlive
#                            the specific session that derived this token —
#                            session-start.sh's dedup overwrites cc-instance.
#                            <pid> with the newest attaching token, so a stale
#                            token's kill-0-only check would otherwise report
#                            "alive" forever via the shared pid. No record at
#                            all (codex: its SessionStart plug exits before
#                            ever reaching that write) falls back to the plain
#                            pid check, unchanged from before.
#   bare "<sid>"            → some live cc-instance.<p> file references it. For
#                            upgrade compatibility a cc-instance whose content
#                            is either exactly "<sid>" or the composite
#                            "<sid>.<numeric>" counts — a pre-upgrade lock holds
#                            a bare sid while cc-instance may already store the
#                            composite, and we must not stale it out instantly.
agmsg_instance_alive() {
  local token="$1"
  [ -n "$token" ] || return 1
  if agmsg_instance_is_composite "$token"; then
    local pid="${token##*.}"
    _agmsg_pid_alive "$pid" || return 1
    local f s
    f="$SKILL_DIR/run/cc-instance.$pid"
    [ -f "$f" ] || return 0
    s="$(cat "$f" 2>/dev/null || true)"
    [ "$s" = "$token" ] && return 0
    return 1
  fi
  local run f p s
  run="$SKILL_DIR/run"
  [ -d "$run" ] || return 1
  for f in "$run"/cc-instance.*; do
    [ -f "$f" ] || continue
    p=${f##*.}
    case "$p" in ''|*[!0-9]*) continue ;; esac
    _agmsg_pid_alive "$p" || continue
    s="$(cat "$f" 2>/dev/null || true)"
    [ "$s" = "$token" ] && return 0
    # upgrade compat: cc-instance stores "<sid>.<pid>" but the lock holds "<sid>"
    if agmsg_instance_is_composite "$s" && [ "${s%.*}" = "$token" ]; then
      return 0
    fi
  done
  return 1
}
