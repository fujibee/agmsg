#!/usr/bin/env bash
set -euo pipefail

# The launcher is detached from codex-monitor.sh and may outlive the shell that
# invoked it. Never retain test-harness result/trace descriptors through the
# dispatcher -> role child -> bridge process chain.
#
# 3 and 4 are closed here, as early as the script can, and then EVERY inherited
# descriptor is closed once lib/close-fds.sh is reachable (just below). Naming
# the two we expect is not enough: the harness picks the number, and a bridge
# that kept it hung a macOS CI shard for 25 minutes with every test already
# green. See scripts/lib/close-fds.sh.
exec 3>&- 4>&-

# Runs outside Codex's tool sandbox and owns the app-server connections. The
# dispatcher starts one bridge per recorded Codex role in this project.
#
# On codex 0.141+ the SessionStart hook cannot resolve the thread id
# (CODEX_THREAD_ID is not exported and no rollout is written for --remote
# sessions), so the bridge discovers the live TUI thread itself via
# thread/loaded/list (`--thread loaded`). If an older codex DID write a request
# file with a real thread id, that id is used instead. See #170, #41.

TYPE="${1:?Usage: codex-bridge-launcher.sh <type> <project_path> <app_server> <parent_pid>}"
PROJECT="${2:?Missing project_path}"
APP_SERVER="${3:?Missing app_server}"
PARENT_PID="${4:?Missing parent_pid}"
ROLE_PAIR="${5:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# Before anything long-lived is spawned. Nothing above forks a process that
# outlives this script, so closing here is as good as closing at line 1 — and
# it is the earliest point at which lib/ is resolvable.
# shellcheck source=../../../lib/close-fds.sh
source "$SCRIPT_DIR/../../../lib/close-fds.sh"
agmsg_close_inherited_fds
# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
# The liveness helpers. Every lifetime and lock-owner check below goes through
# one of them, chosen by where the pid was minted: _agmsg_pid_alive_local for
# the ones this shell or codex-monitor.sh produced, _agmsg_pid_alive for the
# bridge's own pid, which the bridge records itself (#567).
# Sourced explicitly rather than relied on transitively through role-session.sh,
# which only pulls it in when actas-lock.sh has not already been loaded.
# shellcheck source=../../../lib/instance-id.sh
source "$SCRIPT_DIR/../../../lib/instance-id.sh"
PROJECT_HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"
REQUEST_FILE="$RUN_DIR/codex-bridge-request.$PROJECT_HASH"
DISPATCHER_LOCK_RESOURCE="codex-dispatcher:$PROJECT_HASH"
SERVER_PID_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.pid"

# shellcheck source=../../../lib/node.sh
source "$SCRIPT_DIR/../../../lib/node.sh"
NODE_BIN="$(agmsg_resolve_node)"
# shellcheck source=../../../lib/storage.sh
source "$SCRIPT_DIR/../../../lib/storage.sh"
STORAGE_DIR="$(agmsg_storage_dir)"
TAB="$(printf '\t')"

# role-session record (#350): the bridge prefers this role's RECORDED codex thread
# over the app-server's "loaded" thread (see the thread-resolution block below).
# shellcheck source=../../../lib/role-session.sh
source "$SCRIPT_DIR/../../../lib/role-session.sh"
# shellcheck source=../../../lib/resolve-project.sh
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# Canonicalize once so the record's project (stored from the codex actas flow's
# cwd) compares equal to this launcher's project even across a symlinked path.
PROJECT_PHYS="$(agmsg_canonical_path "$PROJECT" 2>/dev/null || printf '%s' "$PROJECT")"

mkdir -p "$RUN_DIR"

# The app-server is shared by every Codex TUI in a project. Bind dispatcher and
# role-child lifetime to that shared process rather than whichever TUI happened
# to start first. Tests/older launchers without the sidecar retain parent-PID
# fallback behavior.
LIFETIME_PID="$(cat "$SERVER_PID_FILE" 2>/dev/null || true)"
if [ -z "$LIFETIME_PID" ] || ! _agmsg_pid_alive_local "$LIFETIME_PID"; then
  LIFETIME_PID="$PARENT_PID"
fi

# Resource currently owned by this process, so the EXIT trap releases whichever
# lock was taken (dispatcher or role child) without a second trap installer.
HELD_LOCK_RESOURCE=""

release_held_lock() {
  rm -f "$IDENTITY_CACHE_MARKER" 2>/dev/null || true
  [ -n "$HELD_LOCK_RESOURCE" ] || return 0
  agmsg_runtime_lock_release "$HELD_LOCK_RESOURCE" "$$"
}

# Acquire <resource>, reclaiming it only from a provably dead owner. Returns 1
# when a LIVE process already holds it — the caller is then a duplicate and must
# exit. Used for both the per-project dispatcher lock and the per-role child
# lock; the semantics (CAS reclaim of a stale generation) are identical.
#
# Re-entrant across `exec "$0" ...`: exec keeps the pid, so the row this process
# already owns is re-acquired by the plain INSERT-OR-IGNORE path on the way back
# in, which is also what re-installs the trap the exec discarded.
acquire_runtime_lock() {
  local resource="$1"
  local owner="" attempt _barrier_attempt _barrier_count
  for attempt in {1..20}; do
    owner="$(agmsg_runtime_lock_acquire "$resource" "$$" 2>/dev/null || true)"
    if [ "$owner" = "$$" ]; then
      HELD_LOCK_RESOURCE="$resource"
      trap release_held_lock EXIT
      trap 'exit 0' INT TERM
      return 0
    fi
    if [ -n "$owner" ] && _agmsg_pid_alive_local "$owner"; then
      return 1
    fi
    if [ -n "${AGMSG_TEST_DISPATCHER_STALE_BARRIER:-}" ]; then
      : > "$AGMSG_TEST_DISPATCHER_STALE_BARRIER.$$"
      for _barrier_attempt in {1..100}; do
        _barrier_count="$(find "$(dirname "$AGMSG_TEST_DISPATCHER_STALE_BARRIER")" \
          -maxdepth 1 -name "$(basename "$AGMSG_TEST_DISPATCHER_STALE_BARRIER").*" \
          -type f 2>/dev/null | wc -l | tr -d ' ')"
        [ "$_barrier_count" -ge 2 ] && break
        sleep 0.05
      done
    fi
    # Replace only the exact stale generation observed above. SQLite serializes
    # both statements with competing reclaimers, so once A replaces stale S
    # with live A, B's `owner = S` delete cannot remove A (true CAS semantics).
    owner="$(agmsg_runtime_lock_acquire "$resource" "$$" "${owner:-0}" 2>/dev/null || true)"
    if [ "$owner" = "$$" ]; then
      HELD_LOCK_RESOURCE="$resource"
      trap release_held_lock EXIT
      trap 'exit 0' INT TERM
      return 0
    fi
    if [ -n "$owner" ] && _agmsg_pid_alive_local "$owner"; then
      return 1
    fi
    sleep 0.05
  done
  return 1
}

resolve_identity() {  # prints "team<TAB>name" lines for the project's codex roles
  "$SCRIPT_DIR/../../../identities.sh" "$PROJECT" "$TYPE" 2>/dev/null \
    | awk -v t="$TAB" 'NF >= 2 { print $1 t $2 }' \
    | { if [ -n "$ROLE_PAIR" ]; then grep -Fx "$ROLE_PAIR" || true; else cat; fi; } \
    | sort -u
}

# identities.sh opens and parses EVERY teams/*/config.json on every call: two
# sqlite3 processes per team file, ~57 processes and ~145 ms total on an
# eight-team install, and a poll loop was paying that several times a second.
# The registrations it reads change only when join / leave / actas rewrite a
# config, so the answer is cached and re-derived only when one of those files
# has actually moved.
#
# Freshness is decided with builtins alone -- glob expansion and `[ -nt ]` -- so
# a hit costs no processes at all. The marker is touched BEFORE the resolve, and
# a config is treated as changed unless the marker is STRICTLY newer than it:
# bash 3.2 compares whole seconds, so "same second as the marker" has to count
# as changed or a write landing inside that second would be missed. That errs
# toward re-resolving for at most one second after a write, never toward
# serving a stale set. The file count is compared too, since removing a team
# leaves nothing behind for `-nt` to notice.
#
# Sets IDENTITY_CACHE in the CURRENT shell — never call it inside $(...), or the
# cache would be written in a subshell and thrown away.
TEAMS_DIR="$SKILL_DIR/teams"
IDENTITY_CACHE=""
IDENTITY_CACHE_COUNT=-1
IDENTITY_CACHE_MARKER="$RUN_DIR/.identity-cache.$$"
IDENTITY_CACHE_FRESH=0   # 1 when the last refresh served the cache unchanged

identity_cache_is_fresh() {
  local f count=0
  [ -f "$IDENTITY_CACHE_MARKER" ] || return 1
  for f in "$TEAMS_DIR"/*/config.json; do
    [ -f "$f" ] || continue
    count=$((count + 1))
    [ "$IDENTITY_CACHE_MARKER" -nt "$f" ] || return 1
  done
  [ "$count" = "$IDENTITY_CACHE_COUNT" ] || return 1
  return 0
}

refresh_identity_cache() {
  if identity_cache_is_fresh; then
    IDENTITY_CACHE_FRESH=1
    return 0
  fi
  IDENTITY_CACHE_FRESH=0
  : > "$IDENTITY_CACHE_MARKER" 2>/dev/null || true
  local f count=0
  for f in "$TEAMS_DIR"/*/config.json; do
    [ -f "$f" ] || continue
    count=$((count + 1))
  done
  IDENTITY_CACHE_COUNT=$count
  IDENTITY_CACHE="$(resolve_identity || true)"
}

# Poll fast while something is happening, then stand down. The startup race the
# tight interval exists for (actas writing the role record just after launch)
# resolves in the first moments; after that a launcher that keeps waking every
# 0.3 s is pure cost, and the delivery it feeds is documented at ~5 s anyway.
# Any observed change resets to the fast step, so responsiveness is unchanged
# exactly when it matters. Deliberately no env override: an interval knob would
# be an interface addition, and nothing here needs to differ per user.
# Exact line membership without the `printf | grep -Fxq` pipeline, which cost
# a process per pair per iteration. Pairs contain a tab but never a newline.
pair_registered() {  # $1 = pair, $2 = newline-separated list
  case $'\n'"$2"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

POLL_STEPS=(0.3 0.6 1.2 2)
poll_index=0
poll_reset() { poll_index=0; }
poll_sleep() {
  sleep "${POLL_STEPS[$poll_index]}"
  [ "$poll_index" -lt 3 ] && poll_index=$((poll_index + 1))
  return 0
}

# Any change here can change the safe subscription set. Include the request
# thread plus each role's recorded session/project, not merely registrations:
# actas/resume rewrites a role record without changing identities.sh output.
# $1 is this tick's already-resolved identity list. It is passed in rather than
# re-resolved so one iteration runs identities.sh once, not twice.
#
# Assigns to SAFETY_STATE instead of printing, and reads the roles with a
# herestring rather than a pipeline, so the whole thing runs in the caller's
# shell. Both matter: agmsg_role_session_load memoizes the record path, and a
# memo written inside a command substitution or a pipeline subshell is
# discarded the moment it is useful.
build_safety_state() {
  local identity="$1"
  local request="" team name
  if [ -f "$REQUEST_FILE" ]; then
    IFS= read -r request < "$REQUEST_FILE" 2>/dev/null || true
  fi
  SAFETY_STATE="request=$request"
  while IFS="$TAB" read -r team name; do
    [ -n "$team" ] || continue
    agmsg_role_session_load "$team" "$name" 2>/dev/null || true
    SAFETY_STATE="$SAFETY_STATE"$'\n'"$team$TAB$name$TAB$AGMSG_ROLE_SESSION_UUID$TAB$AGMSG_ROLE_SESSION_PROJECT"
  done <<< "$identity"
}

# actas may register the role a moment after launch, so retry while the parent
# (codex-monitor.sh) is alive. Multiple identities are intentional (#150).
# The parent only dispatches. Every role receives an independent child launcher
# and therefore an independent bridge bound to its own recorded thread.
if [ -z "$ROLE_PAIR" ]; then
  acquire_runtime_lock "$DISPATCHER_LOCK_RESOURCE" || exit 0
  known_pairs=""
  while agmsg_runtime_lock_verify "$DISPATCHER_LOCK_RESOURCE" "$$" \
    && _agmsg_pid_alive_local "$LIFETIME_PID"; do
    refresh_identity_cache
    current_pairs="$IDENTITY_CACHE"
    [ "$IDENTITY_CACHE_FRESH" = "1" ] || poll_reset
    # Forget pairs that are no longer registered. A child now exits by itself
    # once its own registration is gone, so a stale known_pairs entry would
    # suppress the respawn if that same pair were registered again later.
    retained=""
    while IFS= read -r seen_pair; do
      [ -n "$seen_pair" ] || continue
      pair_registered "$seen_pair" "$current_pairs" || continue
      retained="${retained:+$retained$'\n'}$seen_pair"
    done <<< "$known_pairs"
    known_pairs="$retained"
    while IFS="$TAB" read -r child_team child_name; do
      [ -n "$child_team" ] || continue
      child_pair="$child_team"$'\t'"$child_name"
      pair_registered "$child_pair" "$known_pairs" && continue
      # Close bats' result fd when present; a detached child must not keep the
      # test harness pipe open after its test has completed.
      nohup "$0" "$TYPE" "$PROJECT" "$APP_SERVER" "$LIFETIME_PID" "$child_pair" >/dev/null 2>&1 3>&- 4>&- &
      known_pairs="${known_pairs:+$known_pairs$'\n'}$child_pair"
      poll_reset
    done <<< "$current_pairs"
    poll_sleep
  done
  exit 0
fi

# One live child per (project, role) — #485. Children are `nohup`'d and bound to
# the shared app-server, while the dispatcher runs in the TUI's process group and
# is killed by the SIGHUP a pane teardown delivers. A replacement dispatcher
# starts with an empty known_pairs and re-spawns the ENTIRE child set, so without
# this lock every dispatcher generation left another full set of children behind.
# The lock makes those re-spawns exit on arrival instead of accumulating.
CHILD_LOCK_RESOURCE="codex-child:$PROJECT_HASH:$(printf '%s' "$ROLE_PAIR" | agmsg_sha1)"
acquire_runtime_lock "$CHILD_LOCK_RESOURCE" || exit 0

# Bounded, not open-ended. The dispatcher only spawns a child for a pair it has
# already seen registered, so an empty list here is either the brief actas write
# lag or a role that has genuinely gone away — and the latter arrives via the
# re-exec below, which would otherwise park the child in this loop for as long as
# the app-server lives. Giving up is safe: the dispatcher now forgets a pair when
# its registration disappears, so a re-registered role gets a fresh child.
ids=""
startup_attempts=0
while _agmsg_pid_alive_local "$PARENT_PID" && [ "$startup_attempts" -lt 20 ]; do
  ids="$(resolve_identity || true)"
  [ -n "$ids" ] && break
  startup_attempts=$((startup_attempts + 1))
  sleep 0.3
done
[ -n "$ids" ] || exit 0
build_safety_state "$ids"
safety_state="$SAFETY_STATE"

# Safety over delivery (#150): a role-session record identifies the thread that
# owns a role. Never inject that role's inbox into a different live TUI. Roles
# without a record may share the current project TUI. If the hook could not
# provide a concrete live thread (`loaded`), recorded roles are conservatively
# left unsubscribed rather than guessed. They remain unread for their proper
# next SessionStart.
thread_hint="loaded"
if [ -f "$REQUEST_FILE" ]; then
  _hint_type=""; _hint_thread=""; _hint_app=""
  IFS="$TAB" read -r _hint_type _hint_thread _hint_app < "$REQUEST_FILE" 2>/dev/null || true
  [ -n "${_hint_thread:-}" ] && thread_hint="$_hint_thread"
fi
safe_ids=""
raw_identity_count="$(printf '%s\n' "$ids" | grep -c . || true)"
while IFS="$TAB" read -r candidate_team candidate_name; do
  [ -n "$candidate_team" ] || continue
  # This loop runs in the launcher's own shell (herestring, not a pipeline), so
  # it is also what warms the record-path memo for the rest of the process.
  agmsg_role_session_load "$candidate_team" "$candidate_name" 2>/dev/null || true
  candidate_thread="$AGMSG_ROLE_SESSION_UUID"
  if [ -n "$candidate_thread" ]; then
    candidate_project="$AGMSG_ROLE_SESSION_PROJECT"
    candidate_project_phys="$(agmsg_canonical_path "$candidate_project" 2>/dev/null || printf '%s' "$candidate_project")"
    # A record for another project proves this role's current seat is elsewhere:
    # never consume its unread rows from this project. A lone same-project role keeps #350's legacy recorded-thread affinity even
    # before a concrete request thread is available; multiplexed roles require
    # proof and are excluded while the hint is only `loaded`.
    if [ "$candidate_project_phys" != "$PROJECT_PHYS" ]; then
      continue
    fi
  else
    # A role without a recorded seat has no live TUI to receive its turn.
    continue
  fi
  safe_ids="${safe_ids:+$safe_ids$'\n'}${candidate_team}"$'\t'"${candidate_name}"
done <<< "$ids"
ids="$safe_ids"
# A role record may be written by actas later in this same first turn. An empty
# safe set is therefore transient, not terminal: retry while the parent lives.
if [ -z "$ids" ]; then
  _agmsg_pid_alive_local "$PARENT_PID" || exit 0
  sleep 0.3
  exec "$0" "$TYPE" "$PROJECT" "$APP_SERVER" "$PARENT_PID" "$ROLE_PAIR"
fi

identity_count="$(printf '%s\n' "$ids" | grep -c . || true)"
if [ "$identity_count" = "1" ]; then
  IFS="$TAB" read -r key_team key_name <<EOF
$ids
EOF
  bridge_key="$key_team.$key_name"
else
  bridge_key="$(printf '%s' "$ids" | agmsg_sha1)"
fi
bridge_pairs=()
while IFS="$TAB" read -r candidate_team candidate_name; do
  bridge_pairs+=(--pair "$candidate_team"$'\t'"$candidate_name")
done <<< "$ids"
pidfile="$RUN_DIR/codex-bridge.$bridge_key.pid"
log="$RUN_DIR/codex-bridge.$bridge_key.log"
# Records the app-server URL the live bridge was launched against, so a later
# launcher instance can tell a bridge bound to a stale app-server (old port,
# from before a codex upgrade) from one bound to the current server. See #197/#237.
appserver_file="$RUN_DIR/codex-bridge.$bridge_key.appserver"
# Records the thread a live bridge was bound to (#350), so a later launcher can
# rebind when the resolved thread changes -- e.g. once a role-session record
# appears for a bridge first launched on "loaded", it is torn down and relaunched
# on the recorded thread instead of clinging to the ambiguous "loaded" one.
thread_file="$RUN_DIR/codex-bridge.$bridge_key.thread"
# An explicit AGMSG_CODEX_BRIDGE_CMD is a complete runnable (tests, custom
# wrappers) — run it as-is. Only the default codex-bridge.js is launched through
# a resolved Node, since its env-node shebang fails where a version-manager Node
# is not on PATH (#170).
if [ -n "${AGMSG_CODEX_BRIDGE_CMD:-}" ]; then
  bridge_run=("$AGMSG_CODEX_BRIDGE_CMD")
else
  bridge_run=("$NODE_BIN" "$SCRIPT_DIR/codex-bridge.js")
fi

deregistered_ticks=0
while _agmsg_pid_alive_local "$PARENT_PID"; do
  # Resolved once per iteration and threaded through the fingerprint, so a tick
  # runs identities.sh once rather than twice — and usually not at all, because
  # the resolve is served from the mtime-guarded cache.
  refresh_identity_cache
  current_ids="$IDENTITY_CACHE"
  [ "$IDENTITY_CACHE_FRESH" = "1" ] || poll_reset
  # This child is scoped to one role (`resolve_identity` filters on ROLE_PAIR),
  # so an empty list means the role itself is gone. Nothing upstream retires a
  # child: losing the registration only sends it back through the re-exec, whose
  # pre-loop then spins for as long as the parent lives. Verified: the child was
  # still running 10 s after its role was removed. Two consecutive empties are
  # required because identities.sh also reports empty on a transient read
  # failure, and exiting on one of those would drop a healthy role's delivery.
  if [ -z "$current_ids" ]; then
    deregistered_ticks=$((deregistered_ticks + 1))
    if [ "$deregistered_ticks" -ge 2 ]; then
      if [ -f "$pidfile" ]; then
        old_pid=""
        IFS= read -r old_pid < "$pidfile" 2>/dev/null || true
        # _agmsg_pid_valid, not just non-empty: `kill 0` signals this
        # launcher's own process group, so a corrupt pidfile would tear down
        # the dispatcher and its siblings instead of one stale bridge.
        _agmsg_pid_valid "$old_pid" && kill "$old_pid" 2>/dev/null || true
      fi
      exit 0
    fi
    sleep 0.3
    continue
  fi
  deregistered_ticks=0

  # actas can join a second role after SessionStart. Re-exec through the same
  # safety filter when the registration set changes, replacing the old bridge
  # so the new role is actually subscribed instead of being stranded.
  build_safety_state "$current_ids"
  if [ "$SAFETY_STATE" != "$safety_state" ]; then
    if [ -f "$pidfile" ]; then
      old_pid=""
      IFS= read -r old_pid < "$pidfile" 2>/dev/null || true
      _agmsg_pid_valid "$old_pid" && kill "$old_pid" 2>/dev/null || true
    fi
    exec "$0" "$TYPE" "$PROJECT" "$APP_SERVER" "$PARENT_PID" "$ROLE_PAIR"
  fi
  # Resolve the app-server URL (and thread) this iteration would launch against
  # FIRST, so the reuse check can compare a live bridge's bound server with the
  # current one. Thread source: a request file (older-codex hook) wins; otherwise
  # discover the live TUI thread via thread/loaded/list.
  thread_id="loaded"
  req_app_server="$APP_SERVER"
  if [ -f "$REQUEST_FILE" ]; then
    _rtype=""; _rthread=""; _rapp=""
    IFS="$TAB" read -r _rtype _rthread _rapp < "$REQUEST_FILE" 2>/dev/null || true
    [ -n "${_rthread:-}" ] && thread_id="$_rthread"
    [ -n "${_rapp:-}" ] && req_app_server="$_rapp"
  fi

  # A child launcher is role-scoped. The project request file only supplies a
  # current app-server endpoint; its thread belongs to whichever role most
  # recently fired SessionStart and must never override this role's seat.
  IFS="$TAB" read -r team name <<EOF
$ids
EOF
  agmsg_role_session_load "$team" "$name" 2>/dev/null || true
  rec_thread="$AGMSG_ROLE_SESSION_UUID"
  rec_project="$AGMSG_ROLE_SESSION_PROJECT"
  rec_project_phys="$(agmsg_canonical_path "$rec_project" 2>/dev/null || printf '%s' "$rec_project")"
  if [ -z "$rec_thread" ] || [ "$rec_project_phys" != "$PROJECT_PHYS" ]; then
    # A role with no record (or one seated in another project) stays
    # deliberately unsubscribed (#150) and waits for a record to appear. That
    # wait is open-ended, so it has to be the cheapest path in the file.
    poll_sleep
    continue
  fi
  thread_id="$rec_thread"

  # The role-session record is the sole thread authority (#150 phase 2/#350).

  if [ -f "$pidfile" ]; then
    bridge_pid=""
    IFS= read -r bridge_pid < "$pidfile" 2>/dev/null || true
    if [ -n "$bridge_pid" ] && _agmsg_pid_alive "$bridge_pid"; then
      # Reuse only when the live bridge is bound to the CURRENT app-server. A
      # codex upgrade makes codex-monitor.sh kill the stale app-server and start a
      # fresh one on a new port (#237); a bridge still bound to the old URL stays
      # alive but delivers nothing. The bridge's own exit-on-close covers most of
      # this, but guard the race where the old bridge has not exited yet by the
      # time a new launcher re-checks: an app-server mismatch means tear it down.
      # Reuse only when the live bridge is bound to BOTH the current app-server
      # AND the current thread. The thread guard (#350) is what lets a bridge
      # first launched on the ambiguous "loaded" thread rebind once this role's
      # recorded thread becomes known -- otherwise the app-server match alone
      # would keep the wrong-thread bridge alive indefinitely.
      bound_url=""; bound_thread=""
      IFS= read -r bound_url < "$appserver_file" 2>/dev/null || true
      IFS= read -r bound_thread < "$thread_file" 2>/dev/null || true
      if [ "$bound_url" = "$req_app_server" ] && [ "$bound_thread" = "$thread_id" ]; then
        poll_sleep
        continue
      fi
      kill "$bridge_pid" 2>/dev/null || true
      rm -f "$pidfile" "$appserver_file" "$thread_file"
    else
      rm -f "$pidfile" "$appserver_file" "$thread_file"
    fi
  fi

  nohup "${bridge_run[@]}" \
    --project "$PROJECT" \
    --workspace-root "$STORAGE_DIR" \
    --workspace-root "$SKILL_DIR/teams" \
    --workspace-root "$SKILL_DIR/run" \
    --type "$TYPE" \
    "${bridge_pairs[@]}" \
    --thread "$thread_id" \
    --app-server "$req_app_server" \
    --inline-inbox \
    >>"$log" 2>&1 3>&- 4>&- &
  launched_pid=$!
  printf '%s\n' "$launched_pid" > "$pidfile"
  if [ -n "${AGMSG_CODEX_BRIDGE_CMD:-}" ]; then
    wait "$launched_pid" 2>/dev/null || true
    recorded_pid=""
    IFS= read -r recorded_pid < "$pidfile" 2>/dev/null || true
    [ "$recorded_pid" != "$launched_pid" ] || rm -f "$pidfile"
  fi
  # Record what this bridge is bound to so a later launcher can detect staleness.
  printf '%s' "$req_app_server" > "$appserver_file"
  printf '%s' "$thread_id" > "$thread_file"
  poll_reset
  sleep 1
done
