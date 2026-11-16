#!/usr/bin/env bash
# Shared helpers for the grok-build SessionStart/Stop hooks (agmsgd delivery
# mode, #1973-follow-on grok-queue channel). Sourced, never executed.
#
# The channel (grok-queue.mjs) needs three things per registered grok-build
# seat before it will attempt a nudge: a live grok tool-call process, its
# leader socket path, and whether this session has completed its first turn
# (session/prompt before the first turn's own response lands is observed to
# replay the WHOLE prior transcript via session/update -- see session/resume
# vs session/load in the design memo -- so a nudge before the first turn
# would be unnecessarily expensive even once resume is used, and more to the
# point there is no live turn boundary to attach a queued prompt to yet).
#
# That state is recorded here, in one small JSON file per seat, written by
# SessionStart and updated by Stop -- not read back through agmsg's own
# actas-lock path-encoding scheme, which exists for a different job (resuming
# a CLAUDE CODE session as a role across /clear) and would have to be
# reimplemented byte-for-byte in the daemon's Node code to stay in agreement.
# Keyed instead by a plain SHA-1 of "<team>\x1f<agent>" -- computed the same
# way (agmsg_sha1 here, node:crypto in the channel) on both sides, and this
# key is ours alone, so there is no legacy format to stay compatible with.

# scripts/lib/instance-id.sh is the one file that owns every kill -0 in this
# codebase (enforced by .github/scripts/check-instance-id-ownership.sh);
# liveness here goes through its own _agmsg_pid_alive rather than a second,
# independent kill -0. Guarded so a caller that already sourced it (or will,
# for its own reasons) does not pay for a second source.
declare -F _agmsg_pid_alive >/dev/null 2>&1 || source "${SCRIPT_DIR:?SCRIPT_DIR is not set}/lib/instance-id.sh"

_agmsg_grok_witness_key() {
  printf '%s\x1f%s' "$1" "$2" | agmsg_sha1
}

# Prints the witness file path for (team, agent). RUN_DIR must be set by the
# caller (both session-start.sh and session-end.sh already export it).
agmsg_grok_witness_path() {
  printf '%s/grok-seat.%s.json\n' "$RUN_DIR" "$(_agmsg_grok_witness_key "$1" "$2")"
}

# Prints the path for a seat's own "could not establish a witness" reason
# (Linux real-machine round, 2026-11-15): SessionStart's bounded
# active_sessions.json retry, and grok-stop.sh's own one at the end of the
# first turn, can both still come up empty. This is the ONE place that
# reason is recorded so `agmsg daemon status` can show it (class D) instead
# of only the stderr line grok itself discards for a passive hook. Removed
# by either hook the moment a witness is actually written successfully.
agmsg_grok_pending_path() {
  printf '%s/grok-seat-pending.%s\n' "$RUN_DIR" "$(_agmsg_grok_witness_key "$1" "$2")"
}

# Resolve the SINGLE (team, agent) pair this grok-build session is for, the
# same narrowing session-start.sh's own ROLE_NAME resolution uses for the
# common case: a project registered under exactly one (team, agent) pair for
# type grok-build. A project with more than one grok-build seat is left
# unresolved here (prints nothing, rc 1) rather than guessed at -- the
# channel then sees no witness file and reports the seat unaddressable with
# a plain reason, never silently attached to the wrong seat's session.
agmsg_grok_resolve_seat() {
  local project="$1" pairs pair team agent n
  pairs="$("${SCRIPT_DIR:?SCRIPT_DIR is not set}/identities.sh" "$project" grok-build 2>/dev/null || true)"
  n="$(printf '%s\n' "$pairs" | grep -c '.' || true)"
  [ "${n:-0}" -eq 1 ] || return 1
  pair="$(printf '%s\n' "$pairs" | head -1)"
  team="${pair%%	*}"
  agent="${pair#*	}"
  [ -n "$team" ] && [ -n "$agent" ] && [ "$team" != "$agent" ] || return 1
  printf '%s\t%s\n' "$team" "$agent"
}

# agmsg_grok_active_session_lookup <active_sessions.json> <session_id>
#
# Real-machine round, 2026-11-15 (NG1): a hook's own pid ($$) is the hook
# SCRIPT's pid, which exits the moment the hook returns -- the channel's
# own pid-liveness check then always reads the seat as process_gone. The
# session's REAL process (and its start time, for a future PID-reuse
# guard) is recorded by grok itself in GROK_HOME/active_sessions.json, a
# flat JSON array of per-session objects -- one of which matches this
# SESSION_ID.
#
# Not JSON-parsed in general (no jq/python3 dependency wanted in a hook
# that fires on every turn boundary -- python3 risks the macOS CLT
# trampoline dialog, see lib/require-python3.sh). Instead: scan character
# by character for top-level `{...}` objects (one nesting level -- each
# session record is assumed flat, no nested object/array values; accepted
# risk, flagged for the next real-machine round if active_sessions.json
# turns out to nest), find the one containing this session id as a quoted
# string, and print its whole text verbatim so the caller can pull
# cwd/pid/pid_start out of it (confirmed live, 2026-11-15: the element's
# keys are exactly cwd, opened_at, pid, pid_start, session_id).
#
# Prints the matched object's raw text (one line, newlines stripped) on
# success; nothing, rc 1, if the file is absent/unreadable or no object
# contains this session id.
# True (rc 0) only when <pid> is CONFIRMED gone. Built on instance-id.sh's
# own pid machinery (the file that owns kill -0 and already forces LC_ALL=C
# on a subshell -- not a bare prefix, which misses bash 3.2's builtin --
# around its own error-text match, plus a ps cross-check before calling
# anything gone), never a second, independent kill -0 here, but NOT a bare
# `! _agmsg_pid_alive`: that call answers "is this usable as a liveness
# token at all", and a NO there (an invalid pid shape, or MSYS where it
# cannot ask tasklist at all without a real pid to hand it) is "I don't
# know", not "confirmed dead" -- the review on #1979 caught both: pid "0"
# read back as CONFIRMED DEAD, and a broken `tasklist` on MSYS did too.
# Conservative in the same direction grok-queue.mjs's own pidAlive takes
# (EPERM/unresolvable -> treated as alive). Used by grok-stop.sh to decide
# whether a DIFFERENT session's own stale witness may safely be replaced
# (review on #1979, finding (1)): only when that witness's own recorded
# owner is definitely gone, never merely because this Stop event's
# session_id does not match it.
agmsg_grok_pid_definitely_dead() {
  local pid="$1"
  _agmsg_pid_valid "$pid" || return 1
  # MSYS liveness goes through tasklist, not a signal -- a failure there is
  # "could not observe", never "observed gone". Recovery stays withheld
  # (status shows the pending reason) rather than guessed at.
  case "${MSYSTEM:-}" in MINGW*|MSYS*|UCRT*|CLANG*) return 1 ;; esac
  ! _agmsg_pid_alive_local "$pid"
}

agmsg_grok_active_session_lookup() {
  local path="$1" sid="$2"
  [ -f "$path" ] || return 1
  awk -v sid="\"$sid\"" '
    BEGIN { depth = 0; buf = "" }
    {
      line = $0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "{") {
          depth++
          if (depth == 1) buf = ""
        }
        if (depth >= 1) buf = buf c
        if (c == "}") {
          if (depth == 1 && index(buf, sid) > 0) { print buf; found = 1; exit }
          depth--
        }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "$path"
}
