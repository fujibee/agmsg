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

# agmsg_grok_resolve_seat_for_session <project> <session_id>
#
# Same job as agmsg_grok_resolve_seat, plus one real narrowing step for the
# case that function gives up on: more than one grok-build registration for
# this project. A session's own witness file already names the one
# session_id it belongs to (written by a prior SessionStart/Stop for this
# very session, e.g. a hook re-fire) -- if exactly one candidate's witness
# already carries THIS session id, that candidate is a confirmed fact, not
# a guess, and is returned. If none do (the ordinary first-event case) or
# more than one somehow does (should not happen; treated the same as none,
# never picked between), this is genuinely undecidable with what is known
# right now.
#
# On that undecidable path, with 2+ candidates, this ALSO records why on
# every candidate's own pending-reason file (review on #1979-followup: the
# previous behavior was silent here -- SEAT came back empty and neither
# hook wrote anything, so `agmsg daemon status` could not say more than
# "not on agmsgd delivery, or no SessionStart has run" for any of them,
# indistinguishable from a project that simply never configured grok-build
# at all). Naming the candidates, never picking one, keeps the fix itself
# from becoming the kind of guess it exists to rule out.
#
# Prints "<team>\t<agent>" and returns 0 only when resolved (uniquely
# registered, or uniquely narrowed by session id); prints nothing, returns
# 1, otherwise -- including the zero-registrations case, which is a
# different situation (not ambiguous, just absent) and gets no pending
# reason written here.
agmsg_grok_resolve_seat_for_session() {
  local project="$1" sid="${2:-}" pairs n pair t a wpath wsid match="" names=""
  pairs="$("${SCRIPT_DIR:?SCRIPT_DIR is not set}/identities.sh" "$project" grok-build 2>/dev/null || true)"
  n="$(printf '%s\n' "$pairs" | grep -c '.' || true)"
  if [ "${n:-0}" -eq 1 ]; then
    pair="$(printf '%s\n' "$pairs" | head -1)"
    t="${pair%%	*}"
    a="${pair#*	}"
    [ -n "$t" ] && [ -n "$a" ] && [ "$t" != "$a" ] || return 1
    printf '%s\t%s\n' "$t" "$a"
    return 0
  fi
  [ "${n:-0}" -ge 2 ] || return 1

  if [ -n "$sid" ]; then
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      t="${pair%%	*}"
      a="${pair#*	}"
      [ -n "$t" ] && [ -n "$a" ] && [ "$t" != "$a" ] || continue
      wpath="$(agmsg_grok_witness_path "$t" "$a")"
      [ -f "$wpath" ] || continue
      wsid="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$wpath" 2>/dev/null | head -1)"
      [ -n "$wsid" ] && [ "$wsid" = "$sid" ] || continue
      if [ -n "$match" ]; then
        match=""
        break
      fi
      match="$t"$'\t'"$a"
    done <<EOF_GROK_PAIRS
$pairs
EOF_GROK_PAIRS
    if [ -n "$match" ]; then
      printf '%s\n' "$match"
      return 0
    fi
  fi

  names="$(printf '%s\n' "$pairs" | awk -F'\t' '{ printf "%s%s/%s", (NR>1?", ":""), $1, $2 }')"
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    t="${pair%%	*}"
    a="${pair#*	}"
    [ -n "$t" ] && [ -n "$a" ] || continue
    agmsg_write_atomic "$(agmsg_grok_pending_path "$t" "$a")" \
      "this project has more than one grok-build registration ($names) and nothing yet distinguishes which one this session belongs to; remove the extra registration to resolve" || true
  done <<EOF_GROK_PAIRS
$pairs
EOF_GROK_PAIRS
  return 1
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
# agmsg_grok_leader_socket_for <session_pid> <grok_home>
#
# The leader socket a grok-build session is attached to, for the witness.
# GROK_LEADER_SOCKET first: a TUI started with --leader/--leader-socket
# passes it to its hooks. A TUI that reached leader mode through
# `use_leader = true` in config.toml (what `agmsg delivery agmsgd` writes)
# passes nothing (measured live on Grok Build 1.0.77: neither the TUI, its
# leader nor the hook shell carries it), so without this the witness of
# every such seat recorded an empty socket and agmsgd never delivered to
# it. Second, then: one `ps` call for a `grok agent leader` whose parent is
# this session's own process -- the leader the TUI itself started. Its
# --leader-socket if given, else GROK_HOME/leader.sock (grok's default).
# Nothing found prints nothing: a plain, non-leader TUI keeps an empty
# socket, so agmsgd still never connects (and never has a leader started)
# for a seat that is not in leader mode -- the reason #1979 removed the
# blind default-path fallback. A leader started by an earlier TUI and
# shared by this one is not this session's child and is not adopted; that
# seat keeps the "not in leader mode" reason. Not on Windows (MSYS ps has
# no args column for native processes).
agmsg_grok_leader_socket_for() {
  local pid="$1" grok_home="$2" line args sock=""
  if [ -n "${GROK_LEADER_SOCKET:-}" ]; then
    printf '%s\n' "$GROK_LEADER_SOCKET"
    return 0
  fi
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  case "${MSYSTEM:-}" in MINGW*|MSYS*|UCRT*|CLANG*) return 0 ;; esac
  line="$(ps -A -o ppid= -o args= 2>/dev/null | awk -v p="$pid" '$1 == p && / agent leader( |$)/ && $2 ~ /grok$/ { sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); print; exit }')" || line=""
  [ -n "$line" ] || return 0
  args=" $line "
  case "$args" in
    *" --leader-socket="*) sock="${args#* --leader-socket=}"; sock="${sock%% *}" ;;
    *" --leader-socket "*) sock="${args#* --leader-socket }"; sock="${sock%% *}" ;;
  esac
  [ -n "$sock" ] || sock="$grok_home/leader.sock"
  printf '%s\n' "$sock"
}

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
