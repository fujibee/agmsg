#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# Stream new agmsg messages for the current session as they arrive.
#
# Intended to be launched by Claude Code's Monitor tool from the SessionStart
# hook (`session-start.sh`), but also works standalone as `tail -f` for
# inbox: any agent runtime that can read stdout can consume it.
#
# Usage: watch.sh <session_id> <project_path> <agent_type> [active_name]
#
# Behavior:
#   - Resolves (team, agent) pairs for (project_path, agent_type) via
#     identities.sh. By default, subscribes to messages addressed to any
#     of those pairs.
#   - When [active_name] is given, narrows the subscription to only pairs
#     whose agent name matches — useful for `actas` exclusive role mode.
#   - Inbox and monitor share the driver's persistent per-(team,agent) read
#     cursor. A restart resumes from consumed state, and a fresh watcher delivers
#     existing unread messages instead of jumping over them. See the
#     read-state synchronization specification.
#   - Polls the SQLite DB at AGMSG_WATCH_INTERVAL seconds (default 5, also
#     overridable via the delivery.monitor.poll_interval config key).
#   - Emits one line per new message:
#         <ts> | <team> | <from> → <to> | <body>
#     Newlines in body are escaped to literal "\n" so each message stays a
#     single line — easier for Monitor to deliver as one event.
#   - Writes a pidfile at ~/.agents/agmsg/run/watch.<session_id>.pid and
#     removes it on EXIT / SIGTERM / SIGINT.

# session_id is normally baked into the launch command (CLAUDE_CODE_SESSION_ID /
# GROK_SESSION_ID). An empty first arg is tolerated and resolved below (after the
# libs are sourced) rather than failing hard, so a runtime that cannot bake one
# in — notably Grok Build's `monitor` tool, where "$GROK_SESSION_ID" expands to
# empty — still starts the watcher. project_path and agent_type are required.
SESSION_ID="${1:-}"
[ "$SESSION_ID" = "-" ] && SESSION_ID="" # #477: caller sentinel for empty session id
PROJECT_PATH="${2:?Missing project_path}"
AGENT_TYPE="${3:?Missing agent_type}"
ACTIVE_NAME="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
agmsg_storage_load
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# Terminal driver registry — the graceful-despawn teardown resolves this
# member's own pane through it. Guarded: an install predating the terminals
# axis simply has no registry, and close_own_placement says so rather than
# reaching for $TMUX_PANE behind its own back.
# shellcheck disable=SC1091
[ -r "$SCRIPT_DIR/lib/terminal-registry.sh" ] && . "$SCRIPT_DIR/lib/terminal-registry.sh"

# Resolve a session id when the launcher could not bake one in (empty first arg).
# Grok Build's `monitor` tool runs the watcher with $GROK_SESSION_ID unset, so
# neither the env var nor the instance-id ppid walk (it keys on the claude/codex
# agent binaries) yields grok's session. Bind to a composite "<session_id>.<grok
# _pid>" instead — keyed this way the watermark/pidfile are stable across watcher
# relaunches (no replay gap) and liveness-gated on the grok pid, so the watcher
# self-exits once grok dies rather than lingering as a bare-id orphan (#245).
# agmsg_grok_instance_id handles both `grok --resume <id>` and a fresh `grok`
# (no --resume). Fall back to a throwaway id only if no live grok is found, so the
# watcher still starts (#238). Uses the raw project path the watcher was launched
# with, before agmsg_resolve_project rewrites it, to match grok's session dir.
if [ -z "$SESSION_ID" ]; then
  case "$AGENT_TYPE" in
    grok-build)
      SESSION_ID="$(agmsg_grok_instance_id "$PROJECT_PATH" 2>/dev/null || true)"
      # A fresh grok watcher reaps bare-id grok watchers left behind by older
      # (pre-composite) versions whose grok has since exited (#245). Specific-PID
      # kill only — never a pattern kill.
      agmsg_reap_orphan_grok_watchers "$PROJECT_PATH" "$$" 2>/dev/null || true
      ;;
  esac
  [ -z "$SESSION_ID" ] && SESSION_ID="agmsg-$(compat_uuidgen | tr 'A-Z' 'a-z')"
fi

# Resolve the session's real project root (see #92). The actas/drop/ensure-
# monitor flows relaunch this watcher with a raw "$(pwd)"; without resolution a
# watcher started from a subdir/worktree finds no registration and exits, so
# actas would switch the from-line yet silently kill the receive side. A
# detached watcher (no agent process to walk to) degrades to the ancestor /
# git-common-dir signals, which still recover the nested/worktree cases.
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

# Disambiguate parallel --continue/--resume sessions that share a session_id
# (#93). All per-process state below — pidfile, actas owner, ready
# sentinel — keys on this per-process instance id rather than the bare
# session_id, so two processes that share a session_id no longer collide on the
# same pidfile and kill each other (#66 was a within-session dedup; here it must
# not fire across sibling processes). Idempotent: the SessionStart directive
# already passes a composite id (no re-derive); the command template's manual
# monitor/actas/drop steps pass a bare session_id and we self-derive here.
SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$AGENT_TYPE")"

RUN_DIR="$SKILL_DIR/run"
PIDFILE="$RUN_DIR/watch.$SESSION_ID.pid"
LOGFILE="$RUN_DIR/watch.$SESSION_ID.log"

# Everything this process has to say, somewhere a person can read afterwards.
#
# stderr alone was not that place (#691). In the configuration this actually
# runs in, fd2 is /dev/null: the watcher's fd1 is the socket to its session and
# its fd2 goes nowhere. So every message explaining an otherwise invisible
# state -- roles skipped, a claim refused, the reason a watcher stopped -- was
# written to a file descriptor with no reader. A delivery investigation then
# has to reconstruct from process tables and database state what the one
# component that knew was unable to say.
#
# Beside the pidfile, because this process already owns that directory and the
# pair is what a reader wants: which pid, and what it thought it was doing.
#
# Bounded by rotation, one generation kept: an unbounded log in a directory
# nobody prunes is its own defect. The ceiling is stated exactly, because the
# first version claimed one it did not deliver -- it compared the size BEFORE
# the write, so a live log at cap-1 could take one more line and end over the
# cap, and a live log already past the cap was moved to `.1` still oversized.
#
# The decision includes the bytes about to be written, so:
#
#   live file    never exceeds cap, EXCEPT when one record is itself larger
#                than cap -- then the file is exactly that record, because
#                rotating first and writing it whole is better than dropping
#                the one line someone is looking for.
#   `.1`         a former live file, so bounded the same way.
#   on disk      at most 2 x max(cap, longest single record).
#
# A record here is one diagnostic line with a timestamp and a pid; the longest
# realistic one is a few hundred bytes against a 128 KiB default.
#
# Still echoed to stderr: when someone runs watch.sh by hand, stderr IS the
# place they are looking, and losing that to make the file work would trade one
# silence for another.
WATCH_LOG_MAX_BYTES="${AGMSG_WATCH_LOG_MAX_BYTES:-131072}"
# Normalized the way INTERVAL above is. What an un-normalized value costs was
# measured rather than assumed, because the first version of this comment named
# a failure that does not happen here: the value never enters `$(( ))`, so it
# cannot be read as a variable name, and this script sets `-u` but not `-e`, so
# nothing dies.
#
# It reaches the right-hand side of `[ ... -gt "$WATCH_LOG_MAX_BYTES" ]`. A
# word there makes the test error non-fatally and read as false, forever, so
# rotation simply never fires and the log grows unbounded -- the one property
# this design was chosen for. A cap of `0` is the opposite failure: every
# record is over it, so each one rotates and throws the previous generation
# away, which is the diagnostics this exists to keep.
#
# Anything that is not a positive integer -- empty, words, 0, negative --
# becomes the default, so a misconfigured cap degrades to the shipped bound
# rather than to no bound or to a one-line window.
case "$WATCH_LOG_MAX_BYTES" in
  ''|*[!0-9]*) WATCH_LOG_MAX_BYTES=131072 ;;
  *) [ "$WATCH_LOG_MAX_BYTES" -gt 0 ] || WATCH_LOG_MAX_BYTES=131072 ;;
esac

# Pairs already reported as storeless, so the notice is once per process.
NO_STORE_REPORTED=""

watch_log() {
  local msg="$*" record size=0 bytes
  printf 'agmsg watch: %s\n' "$msg" >&2
  mkdir -p "$RUN_DIR" 2>/dev/null || return 0
  # Built first, so the rotation decision can weigh what is actually going to
  # be appended rather than only what is already there.
  record="$(printf '%s [%s] %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$msg")"
  if [ -f "$LOGFILE" ]; then
    size="$(compat_file_size "$LOGFILE" 2>/dev/null || echo 0)"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    # +1 for the newline. Rotate when this write WOULD cross the cap, not once
    # it already has.
    #
    # Counted in BYTES, with `wc -c`, because the cap is bytes and so is the
    # size `stat` returns. `${#record}` counts CHARACTERS in a UTF-8 locale, and
    # a team or agent name may legally be Unicode -- the storeless and actas
    # diagnostics put those names in the record. A multibyte line then passes a
    # character-count check and lands over the byte cap, which is the contract
    # this rotation exists to hold. One extra process per diagnostic is nothing:
    # these are emitted a handful of times per watcher, not per poll.
    bytes="$(printf '%s' "$record" | wc -c | tr -d '[:space:]' 2>/dev/null)"
    # If the byte count cannot be had, rotate rather than guess. Falling back
    # to `${#record}` would reinstate the character count this just replaced --
    # the exact wrong unit, and fail-OPEN: the bound would quietly stop holding
    # whenever `wc` is missing or answers oddly. Rotating costs one early
    # generation; the diagnostic itself is still written whole below.
    case "$bytes" in ''|*[!0-9]*) bytes="$WATCH_LOG_MAX_BYTES" ;; esac
    if [ "$(( size + bytes + 1 ))" -gt "$WATCH_LOG_MAX_BYTES" ]; then
      mv -f "$LOGFILE" "$LOGFILE.1" 2>/dev/null || true
    fi
  fi
  # Never fatal: a sandbox that cannot write here must not take delivery down.
  printf '%s\n' "$record" >> "$LOGFILE" 2>/dev/null || true
}

# Close THIS member's own pane at the end of a graceful despawn, through the
# terminal driver named by its placement record.
#
# It used to be `tmux kill-pane -t "$TMUX_PANE"`, which is the asymmetry the v1
# scope named: a tmux member could fold itself away and a herdr member could
# not, for no reason other than which multiplexer the teardown was written
# against. The record already says which terminal placed the pane, and
# despawn.sh already tears down through it; this is the same route for the
# member tearing down ITSELF.
#
# Two things this deliberately does NOT do:
#
# 1. It does not fall back to $TMUX_PANE when the record is unusable. Keeping
#    that fallback would leave tmux on a private path and reinstate the very
#    asymmetry being removed — and it would make the failure invisible, because
#    the one terminal that still worked is the one nobody would notice.
#
# 2. It does not fold a pane it cannot show is its own. `despawn.sh` tears down
#    SOMEBODY ELSE from a record; this path tears down ITSELF, and the two need
#    different proof. A record naming (team, name) says a pane was placed for
#    that seat — it does not say the pane this process is running in IS that
#    pane. Acting on the weaker fact is how a record gets used as authority it
#    was never given. So the record's terminal+id must match what this session
#    resolves to right now, and anything short of a match is reported, not
#    guessed at.
#
# Silence is never the answer here: a pane that should have closed and did not
# is exactly the state an operator cannot see. Every path that declines says
# why, on stderr and in the watcher log.
close_own_placement() {
  local team="$1" name="$2"
  local rec ref rec_term rec_id mine my_term my_id

  rec="$(agmsg_spawn_path "$team" "$name")"
  if [ ! -f "$rec" ]; then
    # A record is written when a pane is PLACED. A seat that joined by hand and
    # never went through spawn has none — normal, not an error, and there is
    # nothing here to close. Say so rather than exiting quietly, because the
    # same silence would also cover "the record was lost".
    watch_log "despawned '$name' (role dropped); no placement record for '$team/$name', so there is no pane to close from here — if a window remains it was not placed by agmsg; close it directly"
    return 0
  fi
  IFS=$'\t' read -r ref _ _ < "$rec"
  if [ -z "$ref" ]; then
    watch_log "despawned '$name' (role dropped); the placement record at $rec is empty, so the pane cannot be identified — close this window manually"
    return 0
  fi

  if ! declare -F agmsg_terminal_ref_terminal >/dev/null 2>&1; then
    watch_log "despawned '$name' (role dropped); the terminal registry is not available in this install, so the recorded pane cannot be closed — close this window manually"
    return 0
  fi

  # The ref parser fails CLOSED (non-zero) on a corrupt/unknown-scheme ref. A bare
  # assignment would leave rec_term/rec_id empty and fall through to the "belongs to
  # someone else" branch with an empty recorded side — a misleading message, and
  # under a caller's `set -e` it would take the watcher down with no log at all.
  # Give the unresolvable ref its OWN contract, in the sibling guards' shape (co1).
  rec_term=""; rec_id=""
  rec_term="$(agmsg_terminal_ref_terminal "$ref")" || rec_term=""
  rec_id="$(agmsg_terminal_ref_id "$ref")" || rec_id=""
  if [ -z "$rec_term" ] || [ -z "$rec_id" ]; then
    watch_log "despawned '$name' (role dropped); the placement record's pane ref ($ref) did not resolve to a terminal and pane id, so the pane cannot be identified — close this window manually"
    return 0
  fi

  # Which pane is THIS process in, right now. resolve-for-name is the strict
  # resolver: it answers only with a self-id it could actually establish, and
  # says why when it cannot. That is the property wanted here — an unidentified
  # pane must not be matched against a record by default.
  #
  # The BARE session id, not $SESSION_ID. watch.sh normalises its argument into
  # an instance id (watch.sh:99), which for claude-code is the composite
  # "<sid>.<pid>" — that composite exists only inside agmsg. What a terminal
  # knows is what the CLI told it at SessionStart, which is the bare sid; herdr
  # stores exactly that in agent_session.value. Handing it the composite asks a
  # question no terminal can answer, and the answer comes back as "this session
  # cannot identify its own pane" — a fail-closed that looks like a resolution
  # problem and is really an identifier mismatch. Caught by the herdr test,
  # which is the whole reason it stubs a session id rather than trusting one.
  mine=""
  if declare -F agmsg_terminal_resolve_name >/dev/null 2>&1; then
    local bare_sid="$SESSION_ID"
    if declare -F agmsg_instance_bare_sid >/dev/null 2>&1; then
      bare_sid="$(agmsg_instance_bare_sid "$SESSION_ID")"
    fi
    mine="$(agmsg_terminal_resolve_name "$bare_sid" 2>/dev/null || true)"
  fi
  if [ -z "$mine" ]; then
    watch_log "despawned '$name' (role dropped); this session cannot identify its own pane, so the recorded placement ($ref) is not provably ours and was left alone — close this window manually"
    return 0
  fi
  my_term="${mine%%	*}"
  my_id="${mine#*	}"

  if [ "$my_term" != "$rec_term" ] || [ "$my_id" != "$rec_id" ]; then
    watch_log "despawned '$name' (role dropped); the placement record names $rec_term:$rec_id but this session is in $my_term:$my_id, so that pane belongs to someone else and was left alone — close this window manually"
    return 0
  fi

  if ! agmsg_terminal_load "$rec_term" 2>/dev/null; then
    watch_log "despawned '$name' (role dropped); the '$rec_term' terminal driver would not load, so the pane could not be closed — close this window manually"
    return 0
  fi
  if ! terminal_despawn "$rec_id" >/dev/null 2>&1; then
    # 13 is the drivers' "unsupported" — plain has no addressable pane, so there
    # is genuinely nothing to close and the member must be told, not left with a
    # window it thinks was folded.
    watch_log "despawned '$name' (role dropped); the '$rec_term' terminal did not close pane $rec_id — close this window manually"
  fi
  return 0
}

# Resolve poll interval. Env var wins over config, default 5s.
INTERVAL="${AGMSG_WATCH_INTERVAL:-}"
if [ -z "$INTERVAL" ]; then
  INTERVAL="$("$SCRIPT_DIR/config.sh" get delivery.monitor.poll_interval 5 2>/dev/null || echo 5)"
fi
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac

mkdir -p "$RUN_DIR" 2>/dev/null || true

# Sequential re-invocation of Monitor for this same session_id leaves the
# previous watch.sh running but loses track of it (pidfile gets clobbered).
# The prior holder has to go. ps args check defends against pid recycling —
# only touch processes whose cmdline still matches our watch.sh. See #66.
#
# When ps is unavailable (e.g. Claude Code sandbox), fall back to kill -0
# which confirms the pid is alive but cannot validate the cmdline.
#
# WHO to displace is decided here; the signal is sent AFTER this process has
# written its own pid (#595). Sending it first is what made the predecessor's
# own EXIT guard unsound: that guard removes the pidfile only if it still
# records the predecessor's pid, and read-check-remove is three steps, so a
# successor writing between the read and the remove has its record deleted by
# a process on its way out. The successor never writes again, so the slot
# stays empty while a live watcher owns it.
#
# Claiming first removes the interleaving rather than narrowing it: once the
# file names the successor before the predecessor is ever signalled, the read
# that the predecessor's cleanup performs cannot see the predecessor's own
# pid, so the guard's condition is false and it deletes nothing.
#
# The comment on that guard already described this order as the one in force.
# It was not; the code signalled first.
PREV_PID_TO_DISPLACE=""
if [ -f "$PIDFILE" ]; then
  prev_pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$prev_pid" ] && [ "$prev_pid" != "$$" ] && _agmsg_pid_alive_local "$prev_pid"; then
    prev_cmd=$(compat_get_cmdline "$prev_pid" 2>/dev/null || true)
    if [ -n "$prev_cmd" ]; then
      if agmsg_cmdline_names_path "$prev_cmd" "$SKILL_DIR/scripts/watch.sh"; then
        PREV_PID_TO_DISPLACE="$prev_pid"
      fi
    else
      # ps unavailable (sandboxed) — skip cmdline validation, rely on kill -0
      PREV_PID_TO_DISPLACE="$prev_pid"
    fi
  fi
fi

# Metadata BEFORE the pidfile, deliberately.
#
# A reader that finds a live pid with no filter file cannot tell what that
# watcher is doing OR which project it serves, so it SKIPS it. Written the other
# way round, every filtered watcher spends its startup window in exactly that
# state, and a scan landing in the window reaches the opposite conclusion from
# the one this metadata exists to support -- it would count nothing where there
# is something to count, or, before the project was recorded, warn about a
# watcher sharing nothing. The pidfile is what makes this process visible at
# all, so nothing may be visible before what describes it (raised in review).
#
# The project is part of the record because RUN_DIR is per INSTALL, not per
# project: two projects using the same install both write here, and their
# watchers do not share a subscription -- the pairs come from the project's own
# registrations. Counting across projects would warn about a hazard that does
# not exist (also raised in review).
FILTERFILE="$RUN_DIR/watch.$SESSION_ID.filter"
# Three lines: role, project, and OWNER PID.
#
# The owner is what makes this survive a successor. The replacement path signals
# the previous watcher and does not wait for it, so the order is: successor
# writes this file, predecessor's EXIT runs, reads the pidfile (still its own
# pid), and removes both -- taking the successor's fresh metadata with it. The
# successor is then live with a pidfile and no filter, which a reader classifies
# as pre-change and skips, so a real second unfiltered watcher in this project
# goes unreported. The pidfile transfers ownership by being overwritten; this
# file has to carry its own (raised in review).
printf '%s\n%s\n%s\n' "${ACTIVE_NAME:-unfiltered}" "$PROJECT_PATH" "$$" > "$FILTERFILE" 2>/dev/null || true

echo $$ > "$PIDFILE"

# The slot is ours on disk; now the previous holder can be told to go (#595).
# Nothing waits for it to finish: it is displaced, not depended on, and its
# EXIT will find a pidfile that names this process and leave it alone.
if [ -n "$PREV_PID_TO_DISPLACE" ]; then
  kill "$PREV_PID_TO_DISPLACE" 2>/dev/null || true
fi

# --- Say when this watcher is sharing an inbox with another (#683). ---
#
# A watcher started WITHOUT an active name subscribes to every (team, agent)
# registered for this project that nobody else has claimed. The read cursor is
# one per pair, so when two such watchers exist, whoever polls first takes the
# row and the other sees nothing -- the comment at the subscription site says
# exactly this. The message is not duplicated and it is not lost loudly: it is
# delivered to one of them, and the other's `inbox.sh` truthfully answers "no
# new messages" because the row was read.
#
# Nothing observable is left behind, which is why this has to be said at the one
# moment something can be said: startup.
#
# NOT a lease. This process still subscribes to exactly what it would have
# subscribed to; it only stops being quiet about the fact that someone else is
# doing the same. Exclusion is a separate decision.
# Only when the hazard is real. A warning printed on every start is a warning
# nobody reads, and an unfiltered watcher running alone is not in danger.
if [ -z "$ACTIVE_NAME" ]; then
  _sharing=0
  for _pf in "$RUN_DIR"/watch.*.pid; do
    [ -f "$_pf" ] || continue
    [ "$_pf" = "$PIDFILE" ] && continue
    _other_pid="$(cat "$_pf" 2>/dev/null || true)"
    case "$_other_pid" in ''|*[!0-9]*) continue ;; esac
    # `_agmsg_pid_alive_local`, not a bare `kill -0`. The bare form reads EPERM
    # as "dead", so a watcher this process cannot signal -- another user, a
    # sandbox -- would be counted as gone and its inbox-sharing left unsaid. The
    # repo enforces this (`no shipped script decides liveness with a bare
    # kill -0`), and it caught this line: the first version used the bare form
    # while the comment above it claimed to use what the rest of the file uses.
    #
    # A pidfile left by a crashed watcher names nobody, which is why liveness is
    # checked at all: counting one would fire the warning on an installation
    # that has no second watcher.
    _agmsg_pid_alive_local "$_other_pid" || continue
    _other_filter="${_pf%.pid}.filter"
    # An absent filter file is a watcher from BEFORE this change. It cannot be
    # asked which project it serves, so it is not counted: warning on it would
    # fire for every unrelated project sharing this install, and this warning is
    # only worth having if it is true. A pre-change watcher in the SAME project
    # is a real hazard that goes unreported here -- named in the PR rather than
    # papered over, and it disappears as installs update.
    [ -f "$_other_filter" ] || continue
    _other_name="$(sed -n '1p' "$_other_filter" 2>/dev/null || true)"
    _other_project="$(sed -n '2p' "$_other_filter" 2>/dev/null || true)"
    # Same project only. RUN_DIR is per install; the subscription is per
    # project, so a watcher in another project shares no pairs with this one.
    [ "$_other_project" = "$PROJECT_PATH" ] || continue
    [ "$_other_name" = "unfiltered" ] || continue
    _sharing=$((_sharing + 1))
  done
  if [ "$_sharing" -gt 0 ]; then
    watch_log "another watcher ($_sharing) is receiving for the same unclaimed roles in this project."
    watch_log "messages addressed to those roles will reach whichever of us polls first, and the others will not see them."
    watch_log "to receive only your own: /agmsg actas <name>"
  fi
fi
# Readiness sentinels this watcher created (see #108). Populated once the
# subscription is resolved; removed on exit so the file is present iff a live
# watcher is currently receiving for that role.
READY_FILES=""
cleanup() {
  # EXIT only removes the pidfile if it still records our pid. A successor
  # watcher (Monitor re-invoked for the same session_id) overwrites $PIDFILE
  # with its own pid before signalling us, so this read sees the successor's
  # pid and leaves its record alone. See #66, and #595 for what happened when
  # the signal came first: read, then the successor's write, then this remove
  # — a guard that is three steps cannot decide anything about a file another
  # process may write between them. The order is what makes it sound, not the
  # comparison.
  #
  # This is still not atomic, and it is not relied on to be: a predecessor
  # that entered cleanup for its OWN reasons before any successor existed can
  # still race a newcomer's write. That window is not the relaunch path and
  # is not what #595 observed.
  local pidfile_pid=""
  [ -f "$PIDFILE" ] && IFS= read -r pidfile_pid < "$PIDFILE" || true
  # Both files are removed by their owner, but they do not share an owner test:
  # the pidfile's owner is whoever it names, and the filter file's is whoever it
  # records. See below for why the pidfile cannot answer for both.
  #
  # Neither may be left behind. A stale pidfile makes the next watcher count a
  # ghost. A stale filter file is worse in the direction that matters: it keeps
  # asserting a role on behalf of a dead process, and if that role is a name,
  # every other watcher reads it as "filtered, not sharing" -- so the warning is
  # SUPPRESSED by a process that no longer exists.
  [ "$pidfile_pid" = "$$" ] && rm -f "$PIDFILE"
  # The filter file is judged on ITS OWN recorded owner, not on the pidfile.
  # During a replacement the pidfile still names the predecessor while the
  # successor's metadata is already on disk, so deciding by the pidfile lets the
  # predecessor delete a file it did not write.
  _ff="$RUN_DIR/watch.$SESSION_ID.filter"
  if [ -f "$_ff" ] && [ "$(sed -n '3p' "$_ff" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$_ff" 2>/dev/null || true
  fi
  if [ -n "$READY_FILES" ]; then
    while IFS= read -r _rf; do
      [ -z "$_rf" ] && continue
      # Only remove a sentinel we still own. A successor actas watcher for the
      # same (team, name) overwrites it with its own session_id before this one
      # exits; without this guard our EXIT could delete the live successor's
      # sentinel. Mirrors the pidfile guard above. See #108 review.
      local _owner=""
      [ -f "$_rf" ] && IFS= read -r _owner < "$_rf" || true
      [ "$_owner" = "$SESSION_ID" ] && rm -f "$_rf" 2>/dev/null || true
    done <<< "$READY_FILES"
  fi
  [ -n "${INSTALL_STAMP:-}" ] && rm -f "$INSTALL_STAMP" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

# A resident process keeps executing the code it was started with. An update
# rewrites the scripts in place (same inode -- confirmed with lsof, #684), so
# after one this watcher is running code from before it while everything it
# talks to has moved on. Measured on the reported pair: a 1.1.13 watcher, after
# `npx agmsg@1.2.0-rc.1 install` landed under it, stayed ALIVE and stopped
# delivering -- the message was never printed and never marked read, and
# nothing was written to stderr. Liveness is exactly what made it invisible.
#
# The guard is a timestamp rather than a version comparison, so it does not
# only catch the table that moved this time. ANY file under scripts/ being
# newer than this watcher's start means the code it is running is no longer the
# code on disk, whatever changed -- which is the class, not the instance.
#
# `run/` is deliberately outside the watched tree: pidfiles and readiness
# sentinels are written by watchers themselves and would trip it immediately.
#
# Keyed on the PID as well as the session id, because two watchers can hold the
# same session id at once: Monitor re-invoked for one session leaves the old
# watcher running until the successor kills it (#66), and both run cleanup. A
# stamp named for the session alone is one file they share, so the loser's EXIT
# trap deletes the winner's. `_install_changed` returns false when its stamp is
# missing, so the successor would go on running with the guard silently off --
# the same shape as the bug this guard exists for, and failing in the same
# reassuring direction. $PIDFILE and $READY_FILES carry ownership checks for
# exactly this; a per-process name gets it without a check to keep in sync.
# Found in review.
#
# A SIGKILLed watcher leaves its stamp behind, which is the same exposure the
# pidfile already has, and the file is empty.
INSTALL_STAMP="$RUN_DIR/.watch-start.$SESSION_ID.$$"
: > "$INSTALL_STAMP" 2>/dev/null || true

# True when anything under scripts/ was written after this watcher started.
# `-print -quit` stops at the first hit, so the common case is one stat-walk
# that exits early rather than a full tree scan every cycle.
_install_changed() {
  [ -f "$INSTALL_STAMP" ] || return 1
  [ -n "$(find "$SCRIPT_DIR" -newer "$INSTALL_STAMP" -print -quit 2>/dev/null)" ]
}

# Resolve subscription set.
PAIRS="$("$SCRIPT_DIR/identities.sh" "$PROJECT_PATH" "$AGENT_TYPE")"
if [ -n "$ACTIVE_NAME" ]; then
  PAIRS=$(printf '%s\n' "$PAIRS" | awk -v n="$ACTIVE_NAME" -F'\t' 'NF >= 2 && $2 == n')
fi

# Honor actas exclusivity locks. A (team, agent) pair currently owned by
# another live session is removed from this watcher's subscription so
# messages addressed to that role only reach the owning session. Pairs we
# own (or that are free) stay in. See #62.
#
# When ACTIVE_NAME is set (the watcher was launched by an `actas` flow),
# we also CLAIM the lock for each surviving pair. Implicit claim here makes
# the exclusivity take effect machine-wide on the next peer watcher cycle,
# without needing the skill cmd templates to call a separate helper. If a
# claim fails because another live session beat us to it, exit with an
# error — the user's host agent surfaces stderr and the original (broad)
# watcher was already stopped by the actas flow, so this state is recoverable
# by `drop` on the other session.
if [ -n "$PAIRS" ]; then
  filtered=""
  skipped=""
  held=""
  while IFS=$'\t' read -r _team _agent; do
    [ -z "$_team" ] && continue
    state=$(actas_lock_state "$_team" "$_agent" "$SESSION_ID")
    case "$state" in
      other:*)
        # If the caller is asking specifically for this name (actas flow),
        # treat the conflict as a hard failure. Otherwise (broad subscribe)
        # silently skip — peer owns the role, we don't need it.
        if [ -n "$ACTIVE_NAME" ]; then
          held="${held:+$held }${_team}/${_agent}(${state#other:})"
        else
          skipped="${skipped:+$skipped }${_team}/${_agent}(${state#other:})"
        fi
        continue
        ;;
    esac
    if [ -n "$ACTIVE_NAME" ]; then
      # Implicit claim — `actas` was the invoking flow. Covers the race
      # where state-check said free but a peer claimed it between then and
      # now.
      result=$(actas_lock_claim "$_team" "$_agent" "$SESSION_ID" 2>/dev/null || true)
      case "$result" in
        held:*)
          held="${held:+$held }${_team}/${_agent}(${result#held:})"
          continue
          ;;
      esac
    fi
    filtered="${filtered:+$filtered$'\n'}${_team}"$'\t'"${_agent}"
  done <<< "$PAIRS"
  PAIRS="$filtered"
  if [ -n "$skipped" ]; then
    echo "agmsg watch: skipping pairs held by other sessions: $skipped" >&2
  fi
  if [ -n "$held" ]; then
    echo "agmsg watch: cannot claim (held by other sessions): $held" >&2
    echo "agmsg watch: run \`/agmsg drop <name>\` in the owning session, then retry." >&2
    exit 1
  fi
fi

if [ -z "$PAIRS" ]; then
  if [ -n "$ACTIVE_NAME" ]; then
    echo "agmsg watch: no registration for agent '$ACTIVE_NAME' in $PROJECT_PATH ($AGENT_TYPE); nothing to do"
  else
    echo "agmsg watch: no available identities (all held by other sessions, or none joined); nothing to do"
  fi
  exit 0
fi

# The read frontier lives in the storage driver, once per (team,agent). Core
# never compares its opaque local-position component. Each pair is scanned and
# consumed independently so a broad watcher cannot advance one role merely by
# delivering another role's traffic.

# DB-open healthcheck (#197). The main loop guards every query with
# `2>/dev/null || true`, so when sqlite3 cannot open the store the watcher keeps
# spinning and silently delivers nothing — a silent outage. The native
# sqlite3.exe / Git Bash path mismatch behind #197 is one trigger (now fixed in
# agmsg_db_path), but permissions, a missing binary, or a corrupt file fail the
# same way. A *missing* DB file is normal (no messages sent yet), so only flag
# the case where the file exists but a trivial query cannot run: emit one line
# on stdout (the Monitor event stream) and exit, turning the silent failure into
# a visible one. Done before the ready sentinel so we never signal "ready" for a
# watcher that cannot read the store.
# Resolved from this watcher's own subscription rather than a bare default:
# the store is selected per team now. Every pair here shares a team (the
# subscription is one project's roster); when stores actually split, this
# becomes one check per distinct team in PAIRS.
DB="$(agmsg_db_path "$(printf '%s\n' "$PAIRS" | head -1 | cut -f1)")" || exit 1
if [ -f "$DB" ] && ! agmsg_sqlite "$DB" "SELECT 1;" >/dev/null 2>&1; then
  echo "ERROR: cannot open message DB $DB"
  exit 1
fi

# Signal readiness. Once the subscription is resolved and the watcher is live,
# this watcher will deliver anything that arrives from here on, so it is safe
# for a leader to start sending. Only exclusive (actas) watchers signal — a
# spawned agent always starts its watcher in actas mode — and the sentinel is
# removed on exit (cleanup), so it tracks "a live watcher is receiving for this
# role". `spawn --wait-ready` polls for it. See #108.
if [ -n "$ACTIVE_NAME" ]; then
  while IFS=$'\t' read -r _rt _ra; do
    [ -z "$_rt" ] && continue
    _rp="$(agmsg_ready_path "$_rt" "$_ra")"
    # Stamp our session_id so cleanup (and a successor watcher) can tell whose
    # sentinel it is — keeps "present iff a live watcher is receiving" honest
    # across a quick actas restart. See #108 review.
    printf '%s\n' "$SESSION_ID" > "$_rp" 2>/dev/null || true
    READY_FILES="${READY_FILES:+$READY_FILES$'\n'}$_rp"
  done <<< "$PAIRS"
fi

# Pairs another session currently holds, so each departure and each return is
# announced once instead of every cycle. Membership is not a decision -- the
# lock is -- it only records what has already been said (#683).
#
# Held as newline-separated entries and compared as EXACT strings, never as
# patterns. A team name is arbitrary UTF-8 minus a path deny-list and an agent
# name minus a JSON-path deny-list (validate.sh), so either may contain glob
# metacharacters, a sed delimiter, or a space. A `case` pattern or an
# `s|…|…|` built out of one is a bug that only appears for some names --
# the class this repo has paid for before with quotes in names (#87). Newline
# is the one byte a name cannot contain, control characters being rejected, so
# it is the safe separator.
HELD_ELSEWHERE=""

_held_elsewhere_has() {
  local want="$1" line
  [ -n "$HELD_ELSEWHERE" ] || return 1
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done <<< "$HELD_ELSEWHERE"
  return 1
}

_held_elsewhere_without() {
  local drop="$1" line out=""
  [ -n "$HELD_ELSEWHERE" ] || return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [ "$line" = "$drop" ] && continue
    out="${out:+$out
}$line"
  done <<< "$HELD_ELSEWHERE"
  printf '%s' "$out"
}

# fix 2 (#1045): a pair whose read cursor never advances while it still has pending
# rows is STUCK -- delivery is failing every cycle and the failure is INVISIBLE: ps
# shows a healthy process, the cursor is frozen, and stdout is silent. The symptom this
# fixes is not "not delivered" but "not knowing it is not delivered". So count, per pair,
# the number of CONSECUTIVE poll cycles the cursor stayed at the same value while a
# pending batch waited -- an EVENT count, not elapsed time, which fires the same on a
# slow and a fast machine (time would misfire on one and never fire on the other). At
# the threshold, print WHY and exit. The report goes to STDOUT deliberately: the
# watcher's stderr is /dev/null in every launcher we ship (#691) and the Monitor tool
# surfaces only stdout as an event, so a reason on stderr would share the fate of the
# delivery it reports on -- exactly the invisibility being fixed. It is a plain
# "agmsg watch:" line, NOT the "ts | team | from -> to | body" delivery shape, so a
# reader does not mistake it for a message. Exiting (rather than looping) makes "the
# monitor stopped" visible; a watcher that ends without a reason cannot be told from a
# crash (#983). The threshold is FIXED, not an env knob -- an empty/0/non-numeric knob
# would silently disable the very guard against silence.
STUCK_THRESHOLD=3
# Per-pair tracker state and its map operations (_stuck_get/_stuck_set/
# _stuck_drop). Kept in a sourced lib so the record framing -- which broke for
# names with spaces once and must not again -- can be unit-tested away from this
# script's poll loop; see lib/watch-stuck-map.sh for the data-structure contract.
STUCK_MAP=""
source "$SCRIPT_DIR/lib/watch-stuck-map.sh"

while true; do
  # The installation changed under us (#684). Say it on STDOUT, not stderr:
  # stdout is the delivery channel the session is reading, and this watcher's
  # stderr goes to /dev/null in every launcher we ship, which is why the
  # original failure was silent for hours. Then exit, so "the monitor stopped"
  # is what the session sees instead of a live process delivering nothing.
  if _install_changed; then
    printf 'agmsg watch: the agmsg installation was updated while this watcher was running, so it is still executing the code from before the update. Exiting rather than appearing to work. Restart this session (or run /agmsg actas <name>) to resume delivery.\n'
    exit 0
  fi
  # Liveness guard (#67): exit promptly once the originating agent session is
  # gone. A plain pipe gives no portable way to notice a *downstream* consumer
  # that closed silently — printf '' raises no EPIPE, and macOS buffers a final
  # write into an already-dead reader — so a quiet watcher whose session died
  # would otherwise spin forever (the macOS-runner 33-min stall; #210's job
  # timeout only caps the symptom). `kill -0` on the agent pid embedded in the
  # composite instance id is portable (Git Bash falls back to tasklist; see
  # _agmsg_pid_alive). Gated on a composite id only: a bare id (degraded, no
  # resolved agent pid) keeps the prior behavior and is not liveness-gated.
  if agmsg_instance_is_composite "$SESSION_ID" && ! agmsg_instance_alive "$SESSION_ID"; then
    # Say which condition fired and which token it decided about (#692). The
    # guard is right; the silence is what costs. A watcher that stops here, one
    # that was killed, one that crashed early and one that was never started
    # were four indistinguishable states -- and a test watcher launched with a
    # session id that does not resolve hits this immediately, so the test then
    # runs against no watcher at all while looking exactly like one that did.
    # That happened twice in one investigation before anyone noticed.
    watch_log "session $SESSION_ID is no longer alive; stopping."
    exit 0
  fi
  while IFS=$'\t' read -r pair_team pair_agent; do
    [ -z "$pair_team" ] && continue
    # Ownership is re-read every cycle, because it can change under a running
    # watcher and nothing else notices. The subscription set and the startup
    # lock check both happen once, above; a session that claims this role
    # afterwards moves the lock file and starts its own watcher, and this
    # process would otherwise keep polling the same pair forever.
    #
    # That is not a harmless duplicate. The read cursor is one per
    # (team, agent) and storage_watch_after excludes rows already read, so
    # whoever polls first TAKES the row and the other sees nothing. When the
    # one that takes it is this stale process, its printf succeeds -- stdout is
    # still an open pipe to a live session -- so the id is marked read and the
    # message is gone, delivered to a stream nobody is reading (#683).
    #
    # Only the lock file is read here, not the whole subscription set: losing a
    # pair is the half a running process can detect for the price of a file
    # read. Gaining one is the caller's job, at the point it creates the team.
    pair_state="$(actas_lock_state "$pair_team" "$pair_agent" "$SESSION_ID" 2>/dev/null || echo free)"
    # actas-fatal: a watcher that exists to serve exactly this one role, and no
    # longer owns it, stops -- and says so on stderr (the only place a reason
    # survives; a watcher that ends without one is indistinguishable from a
    # crash). This is decided here, before the gate, because it EXITS rather than
    # skips; the gate only decides serve-vs-skip for a watcher that keeps running.
    if [ -n "$ACTIVE_NAME" ]; then
      case "$pair_state" in
        other:*)
          watch_log "${pair_team}/${pair_agent} is now held by session ${pair_state#other:}."
          watch_log "this watcher no longer owns that role and is stopping."
          watch_log "messages for it stay unread and reach the session that claimed it."
          exit 0
          ;;
      esac
    fi
    # Serve-or-skip, with the stuck-tracker drop tied to the skip (see _pair_gate
    # in lib/watch-stuck-map.sh). held/nostore -> skip and the count is already
    # forgotten; serve -> proceed. The transition logging stays here, keyed on the
    # verdict, so it is announced once per transition, not once per cycle.
    _pair_gate "$pair_team" "$pair_agent" "$pair_state"
    case "$PAIR_VERDICT" in
      held:*)
        # Broad subscription: this watcher serves other roles too, so skip the
        # pair rather than ending the process -- exiting here would take down a
        # whole session's delivery because one of its roles moved elsewhere.
        # Skipped FOR AS LONG AS someone else holds it: when the holder goes away
        # the lock reads free again and this watcher takes the pair back (a stale
        # lock is free, the startup filter's rule). Announced on each transition,
        # not each cycle, and not only the first time (a second departure must
        # still be visible).
        if ! _held_elsewhere_has "${pair_team}/${pair_agent}"; then
          HELD_ELSEWHERE="${HELD_ELSEWHERE:+$HELD_ELSEWHERE
}${pair_team}/${pair_agent}"
          echo "agmsg watch: ${pair_team}/${pair_agent} was claimed by session ${PAIR_VERDICT#held:}; not serving it while they hold it." >&2
        fi
        continue
        ;;
      nostore)
        # Per team: with a store per team, "one team has no store yet" is a
        # normal state, and a single check outside this loop would silence
        # delivery for every OTHER team as well. Said once per pair per process
        # (#692) -- a line every poll interval would bury the log it exists to
        # make readable.
        case " $NO_STORE_REPORTED " in
          *" $pair_team:$pair_agent "*) ;;
          *) NO_STORE_REPORTED="$NO_STORE_REPORTED $pair_team:$pair_agent"
             watch_log "${pair_team}/${pair_agent}: no store yet; skipping this pair until one exists." ;;
        esac
        continue
        ;;
    esac
    # serve: free or ours, store present. If we had stepped aside for it, say we
    # are taking it back -- otherwise the log shows a role leaving and never
    # returning, which reads as a permanent drop.
    if _held_elsewhere_has "${pair_team}/${pair_agent}"; then
      HELD_ELSEWHERE="$(_held_elsewhere_without "${pair_team}/${pair_agent}")"
      echo "agmsg watch: ${pair_team}/${pair_agent} is unheld again; serving it here." >&2
    fi
    # Read this pair's delivery state -- its read frontier, then the messages
    # past it -- and KEEP THE STATUS separate from the output. A failed read must
    # not collapse to "" and fall into the caught-up arm below: that arm drops the
    # tracker and continues in silence, which is the exact outage #1045 exists to
    # catch, one level earlier. The stuck guard cannot see this one -- a failed
    # scan returns no message_sent row to count, so the pair looks caught up
    # forever. So on a failed observation, say why on stdout (a plain
    # "agmsg watch:" line, not the delivery shape) and exit: a bounded, visible
    # stop, never silent continuation. This is the same failure-is-not-empty
    # collapse the cursor-only fix above closed, at the read itself.
    #
    # The two OTHER reads in this cycle that also fall back to empty are the
    # DIFFERENT case the stuck guard already covers, so they are left as-is: the
    # mktemp and the ':memory:' delivery query (below) can fail to "", but OUT
    # still holds the message_sent rows, so a frozen cursor climbs to the
    # threshold and fires. actas_lock_state's fall back to "free" (above) is a
    # deliberate fail-open (a stale/unreadable lock is free, #595), not this
    # class. Reverting either read here to `|| true` reopens the silent hole --
    # a mutation test asserts it.
    if READ_CURSOR="$(storage_read_cursor_get "$pair_team" "$pair_agent" 2>/dev/null)" \
       && OUT="$(storage_watch_after "$READ_CURSOR" "$pair_team:$pair_agent" 2>/dev/null)"; then
      [ -n "$READ_CURSOR" ] || READ_CURSOR=0
    else
      printf 'agmsg watch: cannot read delivery state for %s — the store read failed, so whether messages are waiting is unknown. Treating "unknown" as "no messages" would leave this watcher alive and silent, so it is exiting instead; restart this session (or run /%s actas <name>) to resume delivery (#1045/#777).\n' \
        "$pair_team:$pair_agent" "$(basename "$SKILL_DIR")"
      cleanup
      exit 0
    fi
    # fix 2 (#1045): update this pair's stuck-cursor tracker (see the block comment
    # before the loop). "Pending" here means real undelivered MESSAGE rows -- not a
    # non-empty OUT. storage_watch_after also emits a trailing "cursor" high-water
    # line, and that line is present for a CAUGHT-UP pair too, because the team's
    # sequence advances whenever ANY pair in the team receives a message. Keying the
    # tracker on [ -n "$OUT" ] would therefore treat every idle pair as perpetually
    # pending, and on any cycle its cursor could not advance (e.g. a delivery stall
    # that is not this pair's fault) the count would climb and fire the guard on a
    # perfectly healthy watcher. So track a pair only while a message_sent row is
    # actually waiting for it; a glob avoids forking grep in the poll loop. When
    # READ_CURSOR is UNCHANGED from the previous cycle delivery did not advance it --
    # count that; at the threshold say why on stdout and exit. With no message row
    # waiting the pair is caught up, so drop its tracker and a future backlog starts
    # a fresh count.
    _agmsg_pair_key="$pair_team:$pair_agent"
    case "$OUT" in
      *'"type":"message_sent"'*)
        IFS=$'\x1f' read -r _agmsg_prev_c _agmsg_prev_n <<< "$(_stuck_get "$_agmsg_pair_key")"
        [ -n "$_agmsg_prev_n" ] || _agmsg_prev_n=0
        if [ "$_agmsg_prev_c" = "$READ_CURSOR" ]; then
          _agmsg_n=$((_agmsg_prev_n + 1))
        else
          _agmsg_n=1
        fi
        if [ "$_agmsg_n" -ge "$STUCK_THRESHOLD" ]; then
          _agmsg_bytes="$(printf '%s' "$OUT" | wc -c | tr -d ' ')"
          printf 'agmsg watch: delivery for %s is STUCK — its read cursor (%s) has not advanced for %s poll cycles while %s bytes of messages wait behind it, so nothing is being delivered and nothing is being marked read. This watcher is exiting rather than looping in silence; restart this session (or run /%s actas <name>) to resume delivery. If it recurs, the pending batch may be hitting a system limit (#1045/#777).\n' \
            "$_agmsg_pair_key" "$READ_CURSOR" "$_agmsg_n" "$_agmsg_bytes" "$(basename "$SKILL_DIR")"
          cleanup
          exit 0
        fi
        _stuck_set "$_agmsg_pair_key" "$READ_CURSOR" "$_agmsg_n"
        ;;
      *)
        _stuck_drop "$_agmsg_pair_key"
        ;;
    esac
    if [ -n "$OUT" ]; then
    # The quote is held in a variable, never written as \' in the pattern: bash 3.2
    # (macOS /bin/bash) keeps the backslash of a \' REPLACEMENT, so the inline form
    # doubles a quote into \'\' there while producing '' on bash 4+. Same shape as
    # _sqlite_sync_lit_into in sqlite-sync.sh, which documents the same hazard.
    _AGMSG_SQ="'"
    _arr="[$(printf '%s' "$OUT" | paste -sd, -)]"
    # #777/#1045: build the statement into a temp file and pass it on STDIN, the way
    # history.sh (#899) already does. Interpolating the pending batch into the SQL and
    # handing the whole string to sqlite3 as ONE argv element exceeds the per-argument
    # length ceiling once a backlog (or a single long body) grows past it; the call then
    # fails, and because the failure was swallowed here the cursor never advanced and the
    # SAME oversized batch came back every cycle -- a silent, self-locking outage. The
    # temp file is removed inline (no EXIT trap, which would displace the watcher's own
    # cleanup trap); the stuck-cursor guard below is the backstop for any OTHER cause.
    _agmsg_watch_sql="$(mktemp "${TMPDIR:-/tmp}/agmsg-watch-rows.XXXXXX" 2>/dev/null || true)"
    if [ -n "$_agmsg_watch_sql" ]; then
      {
        printf "%s\n" "SELECT COALESCE(json_extract(value,'\$.type'),'') || char(31) ||"
        printf "%s\n" "       COALESCE(json_extract(value,'\$.id'),'') || char(31) ||"
        printf "%s\n" "       COALESCE(json_extract(value,'\$.at'),'') || char(31) ||"
        printf "%s\n" "       COALESCE(json_extract(value,'\$.team'),'') || char(31) ||"
        printf "%s\n" "       COALESCE(json_extract(value,'\$.from'),'') || char(31) ||"
        printf "%s\n" "       COALESCE(json_extract(value,'\$.to'),'') || char(31) ||"
        printf "%s\n" "       replace(replace(replace(COALESCE(json_extract(value,'\$.body'),''), char(13), ''), char(10), '\\n'), char(9), '\t') || char(31) ||"
        printf "%s\n" "       COALESCE(json_extract(value,'\$.cursor'),'')"
        printf "FROM json_each('"
        printf '%s' "${_arr//$_AGMSG_SQ/$_AGMSG_SQ$_AGMSG_SQ}"
        printf "');\n"
      } > "$_agmsg_watch_sql"
      ROWS="$(agmsg_sqlite ':memory:' < "$_agmsg_watch_sql" 2>/dev/null || true)"
      rm -f "$_agmsg_watch_sql"
    else
      ROWS=""
    fi

    FINAL_CURSOR=""
    DELIVERED_IDS=()
    DESPAWN_TARGET=""
    while IFS=$'\x1f' read -r kind id ts team from to body cursor; do
      [ -z "$kind" ] && continue
      if [ "$kind" = "cursor" ]; then
        FINAL_CURSOR="$cursor"
        continue
      fi
      [ "$kind" = "message_sent" ] || continue
      [ -z "$id" ] && continue
      # Control message: a leader's `despawn` sends `ctrl:despawn` to this
      # role. Tear ourselves down rather than printing it — drop the role
      # (releases the lock + registration) then close our own tmux pane,
      # which also ends the agent CLI sharing it. Deterministic teardown, no
      # dependence on the agent LLM noticing the message. See #109.
      if [ "$body" = "ctrl:despawn" ]; then
        DELIVERED_IDS+=("$id")
        # Only an EXCLUSIVE watcher dedicated to exactly this role tears
        # itself down. A broad-subscription watcher (e.g. a leader whose
        # default watcher subscribes to every project role, including the
        # despawn target) must NOT act on it — its $TMUX_PANE is the leader's
        # own pane, so killing it would take down the leader's session. The
        # spawned member's watcher runs in actas mode (ACTIVE_NAME=$to) in its
        # own pane; that's the one meant to respond. A broad watcher `continue`s
        # and consumes the control row without acting. An exclusive target
        # consumes the complete scanned batch before teardown.
        if [ -z "$ACTIVE_NAME" ] || [ "$to" != "$ACTIVE_NAME" ]; then
          continue
        fi
        DESPAWN_TARGET="$to"
        continue
      fi
      if ! printf '%s | %s | %s → %s | %s\n' "$ts" "$team" "$from" "$to" "$body"; then
        cleanup
        exit 0
      fi
      DELIVERED_IDS+=("$id")
    done <<< "$ROWS"
    if [ -n "$FINAL_CURSOR" ]; then
      # Bash 3 with `set -u` treats an empty array expansion as unbound. A
      # cursor-only page is valid, so advance it without optional IDs in that
      # case (and preserve exact delivered IDs when there are any).
      if [ "${#DELIVERED_IDS[@]}" -gt 0 ]; then
        storage_read_cursor_consume "$pair_team" "$pair_agent" "$FINAL_CURSOR" \
          "${DELIVERED_IDS[@]}" >/dev/null 2>&1 || true
      else
        storage_read_cursor_consume "$pair_team" "$pair_agent" "$FINAL_CURSOR" \
          >/dev/null 2>&1 || true
      fi
    fi
    if [ -n "$DESPAWN_TARGET" ]; then
      "$SCRIPT_DIR/reset.sh" "$PROJECT_PATH" "$AGENT_TYPE" "$DESPAWN_TARGET" "$SESSION_ID" >/dev/null 2>&1 || true
      close_own_placement "$pair_team" "$DESPAWN_TARGET"
      exit 0
    fi
    fi
  done <<< "$PAIRS"

  # Run sleep in the background and `wait` for it so signal traps fire
  # immediately. Bash defers traps while a foreground builtin like `sleep`
  # is blocking, which would otherwise delay shutdown by up to $INTERVAL.
  sleep "$INTERVAL" 3>&- 4>&- &
  wait $! 2>/dev/null
done
