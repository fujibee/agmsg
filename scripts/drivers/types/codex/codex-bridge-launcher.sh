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
bridge_pair_values=()
while IFS="$TAB" read -r candidate_team candidate_name; do
  bridge_pairs+=(--pair "$candidate_team"$'\t'"$candidate_name")
  bridge_pair_values+=("$candidate_team"$'\t'"$candidate_name")
done <<< "$ids"
# This launcher's identity, hashed the same way the bridge hashes its lease
# (scripts/drivers/types/codex/codex-bridge.js writeLease): SHA-1 of the ASCII-
# sorted per-pair SHA-1 hashes, joined by newlines. Hashing each pair FIRST means
# the set order is decided by sorting hex (pure ASCII), so a byte sort here and a
# code-unit sort in JS agree even for non-ASCII team/name -- the locale/Unicode
# sort-order gap a raw-value sort would leave. PROJECT_HASH (above) is the project
# half. Comparing hashes -- never raw values -- is what keeps a separator inside a
# path or role from being misread as identity (#943).
_pair_hashes=""
for _pv in "${bridge_pair_values[@]}"; do
  _pair_hashes="$_pair_hashes$(printf '%s' "$_pv" | agmsg_sha1)
"
done
BRIDGE_PAIRS_HASH="$(printf '%s' "$(printf '%s' "$_pair_hashes" | LC_ALL=C sort | sed '/^$/d')" | agmsg_sha1)"


# This launcher's full identity as one key: sha1 of the project hash and the
# pair-set hash together. Everywhere identity is used -- the reap match AND the
# spawn-rate reservation below -- keys on BOTH halves, so nothing is scoped by
# role alone (project-blind keying is the bug class that produced #721 and the
# earlier .meta collision).
IDENTITY_HASH="$(printf '%s\n%s' "$PROJECT_HASH" "$BRIDGE_PAIRS_HASH" | agmsg_sha1)"

# How long to wait for a reaped bridge to exit before treating it as stuck. The
# real bridge shuts down async on SIGTERM and holds its thread as writer until it
# does, so this outlasts an ordinary shutdown.
_REAP_WAIT_TICKS=50

# A process's start token, at the best precision the platform offers and by the
# SAME method codex-bridge.js writeLease() records for itself, so the two agree:
#   Linux -> /proc/<pid>/stat field 22 (starttime in clock ticks): lossless, so a
#            recycled pid is always distinguishable from the one we leased.
#   else  -> `ps -o lstart=` (second precision). Echoes "<src><TAB><token>";
#            returns non-zero (indeterminable) so the caller fails closed.
#   win32 -> Process.StartTime.Ticks via PowerShell -- the SAME single source
#            codex-bridge.js startToken() writes, so both sides always agree.
#            WMIC's CreationDate is cheaper but deprecated (already gone from some
#            Windows 11 installs); a "WMIC, else PowerShell" order on each side
#            independently would let the two resolve DIFFERENT sources for the
#            same process whenever only one of them can reach wmic.exe, and their
#            differently-FORMATTED tokens would make the reaper read a live
#            bridge's lease as another process's. powershell.exe and pwsh return
#            identical Ticks (measured), so falling back between those two
#            binaries introduces no such divergence.
#
# ★The Windows branch is taken INSTEAD of the /proc branch, not merely before it.
# MSYS/Cygwin do expose a working /proc (field 22 and all), but it is keyed by the
# emulation layer's OWN pid space, while a lease records the Windows pid that
# codex-bridge.js sees as process.pid -- the two are unrelated numbers for the
# same process (measured on MINGW64: MSYS pid 3065729 vs winpid 1456). Letting
# /proc win here would silently return the start time of whatever UNRELATED MSYS
# process happens to sit at that number, and the reaper would then compare a
# well-formed token against the wrong process: exactly the recycled-pid confusion
# the token exists to prevent, only harder to notice because nothing errors.
_agmsg_is_windows() {
  case "${_AGMSG_UNAME_S:=$(uname -s 2>/dev/null || echo unknown)}" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

_start_token() {
  local pid="$1" s r tok bin
  local -a a
  if _agmsg_is_windows; then
    for bin in powershell.exe pwsh; do
      # `tr -d '\r'` because PowerShell writes CRLF and Node's .trim() on the
      # writer side strips it there, so both end up with the bare digits.
      tok="$("$bin" -NoProfile -NonInteractive -Command \
        "(Get-Process -Id $pid).StartTime.Ticks" 2>/dev/null | tr -d '\r' | head -n 1)"
      tok="${tok#"${tok%%[![:space:]]*}"}"
      tok="${tok%"${tok##*[![:space:]]}"}"
      case "$tok" in ''|*[!0-9]*) continue ;; esac
      printf 'pwsh\t%s' "$tok"
      return 0
    done
    return 1
  fi
  if [ -r "/proc/$pid/stat" ]; then
    s="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    r="${s##*)}"
    read -ra a <<< "$r"
    tok="${a[19]:-}"
    case "$tok" in ''|*[!0-9]*) return 1 ;; esac
    printf 'proc\t%s' "$tok"
    return 0
  fi
  tok="$(ps -o lstart= -p "$pid" 2>/dev/null)"
  # Trim leading/trailing whitespace only (ps pads); Node's .trim() on the writer
  # side does the same, and both leave the internal single/double spaces intact,
  # so the two strings compare equal.
  tok="${tok#"${tok%%[![:space:]]*}"}"
  tok="${tok%"${tok##*[![:space:]]}"}"
  [ -n "$tok" ] || return 1
  printf 'ps\t%s' "$tok"
  return 0
}

# Parse a lease under an EXACT v=1 schema and fail closed on anything else. Sets
# lproj/lpairs/lhost/lpid/lstart/lstartsrc and returns 0 only when the file is
# precisely the seven expected keys, each once, no unknown or duplicate or extra
# line, hashes 40-hex, pid numeric, startsrc proc|ps|pwsh. A malformed, truncated, or
# tampered lease returns non-zero, so the reaper never kills on a doubtful one.
_read_lease() {
  local file="$1" line k v nlines=0 lv=""
  local sv=0 sproj=0 spairs=0 shost=0 spid=0 sstart=0 ssrc=0
  lproj=""; lpairs=""; lhost=""; lpid=""; lstart=""; lstartsrc=""
  while IFS= read -r line || [ -n "$line" ]; do
    nlines=$((nlines + 1))
    case "$line" in *=*) ;; *) return 1 ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      v)        sv=$((sv + 1)); lv="$v" ;;
      project)  sproj=$((sproj + 1)); lproj="$v" ;;
      pairs)    spairs=$((spairs + 1)); lpairs="$v" ;;
      host)     shost=$((shost + 1)); lhost="$v" ;;
      pid)      spid=$((spid + 1)); lpid="$v" ;;
      start)    sstart=$((sstart + 1)); lstart="$v" ;;
      startsrc) ssrc=$((ssrc + 1)); lstartsrc="$v" ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ "$nlines" -eq 7 ] || return 1
  [ "$sv$sproj$spairs$shost$spid$sstart$ssrc" = "1111111" ] || return 1
  [ "$lv" = "1" ] || return 1
  case "$lproj" in *[!0-9a-f]*|"") return 1 ;; esac; [ "${#lproj}" -eq 40 ] || return 1
  case "$lpairs" in *[!0-9a-f]*|"") return 1 ;; esac; [ "${#lpairs}" -eq 40 ] || return 1
  case "$lpid" in *[!0-9]*|"") return 1 ;; esac
  case "$lstartsrc" in proc|ps|pwsh) ;; *) return 1 ;; esac
  [ -n "$lhost" ] || return 1
  [ -n "$lstart" ] || return 1
  # proc's starttime ticks and .NET's StartTime.Ticks are both bare integers, so
  # a lease carrying anything else under either label fails closed here. ps stays
  # exempt: its lstart is a human date string whose punctuation varies by
  # platform, and writer and reader only ever compare it byte for byte.
  case "$lstartsrc" in
    proc|pwsh) case "$lstart" in *[!0-9]*|"") return 1 ;; esac ;;
  esac
  return 0
}

# Reap every live bridge that is EXACTLY this (project, pair-set), identified by
# the per-PID lease it published (codex-bridge-lease.<pid>) -- not by
# reconstructing argv from ps, which is a lossy representation that misread
# identity five different ways. ps is used ONLY to enumerate live pids and to
# read each one's start token. Every doubt fails CLOSED (no kill): a missing lease
# (a legacy bridge), a malformed or partial one, a different or absent host, a
# hash that is not ours, a start token that no longer matches. Non-Windows only
# (the pid is only killable in this shell's pid namespace; Windows is the #458
# mismatch) and a no-op with no process lister.
_reap_orphan_bridges() {
  case "${MSYSTEM:-}" in MINGW*|MSYS*|CLANGARM*) return 0 ;; esac
  command -v pgrep >/dev/null 2>&1 || return 0
  local myhost pid lease cur killed="" waited
  local lproj lpairs lhost lpid lstart lstartsrc
  myhost="$(hostname 2>/dev/null)"
  [ -n "$myhost" ] || return 0
  for pid in $(pgrep -f 'codex-bridge\.js' 2>/dev/null); do
    lease="$RUN_DIR/codex-bridge-lease.$pid"
    [ -f "$lease" ] || continue
    _read_lease "$lease" || continue
    [ "$lpid" = "$pid" ] || continue
    [ "$lhost" = "$myhost" ] || continue
    [ "$lproj" = "$PROJECT_HASH" ] || continue
    [ "$lpairs" = "$BRIDGE_PAIRS_HASH" ] || continue
    # Reuse guard: the LIVE pid's actual start token (same source) must still equal
    # the lease's. A recycled pid has a different token (lossless on Linux), so it
    # is spared.
    cur="$(_start_token "$pid")" || continue
    [ "$cur" = "$lstartsrc	$lstart" ] || continue
    kill "$pid" 2>/dev/null || true
    killed="$killed$pid	$lstartsrc	$lstart
"
  done
  [ -n "$killed" ] || return 0
  # THE RULE for every check here (add a new one? read this first): a failed
  # observation is proof of NOTHING. Killing and spawning each need their OWN
  # positive proof, and on any observation failure we do NOTHING -- the timeout
  # bounds the wait, a failed read is never re-read as state:
  #   kill  only with proof of IDENTITY  -- the start token READ and MATCHED (above)
  #   spawn only with proof of EXIT      -- the killed pid's token READ and now names
  #                                         a DIFFERENT process (a replacement, below)
  # Wait for each killed pid to exit. The ONLY positive proof of exit we can trust
  # here is a start token that reads and DIFFERS: the pid now hosts another process,
  # so the one we killed is gone. Everything else keeps waiting -- a token that reads
  # UNCHANGED (still alive), and, deliberately, a token we could NOT read (which
  # proves nothing: /proc or ps can fail transiently). We do NOT consult
  # _agmsg_pid_alive_local: its false is not a trustworthy absence proof -- a
  # transient ps failure there returns "gone" (missing pipefail, #954), the exact
  # observation-as-state trap this loop exists to avoid. So a normal exit falls
  # through to the timeout and returns 1: we do NOT spawn this pass, so a bridge
  # still holding the thread as writer is never double-started (#935). The cost is
  # not a stall but one cycle -- the next pass no longer sees the exited pid in
  # pgrep and spawns then.
  while IFS="$TAB" read -r pid lstartsrc lstart; do
    [ -n "$pid" ] || continue
    waited=0
    while :; do
      cur="$(_start_token "$pid")"
      if [ -n "$cur" ] && [ "$cur" != "$lstartsrc	$lstart" ]; then break; fi
      if [ "$waited" -ge "$_REAP_WAIT_TICKS" ]; then return 1; fi
      sleep 0.1; waited=$((waited + 1))
    done
  done <<EOF
$killed
EOF
  return 0
}

# A ceiling on bridge spawns for this identity: at most _SPAWN_MAX in _SPAWN_WINDOW
# seconds. The reap converges duplicates to one, but a bridge that cannot stay up
# (a launcher dying before it records the pidfile) would reap-and-respawn every
# tick; this bounds that churn.
#
# Reservations are self-expiring marker FILES, not a shared lock. A lock has to be
# reclaimed when its holder dies, and every read->decide->reclaim scheme races
# (an owner check cannot be made atomic with the unlink -- ABA). So instead each
# spawn creates its own uniquely named marker carrying its timestamp IN THE NAME;
# the count is just how many unexpired markers exist. Nothing is ever reclaimed:
# a crashed launcher's marker simply ages out of the window and any later pass
# prunes it. Reserve-then-count means a concurrent pair both count each other and
# both back off, so the cap is never exceeded (it may briefly under-count, which
# for a coarse throttle is the safe direction).
_SPAWN_WINDOW=30
_SPAWN_MAX=5
_spawn_rate_ok() {
  local prefix="codex-bridge-rate.$IDENTITY_HASH."
  local now cutoff mine f base ts n=0
  now="$(date +%s)"
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  cutoff=$((now - _SPAWN_WINDOW))
  # Reserve: create MY marker with an exclusive (noclobber) create so two
  # launchers never share one name. The timestamp lives in the name, so the file
  # is empty and there is no create-then-write window for a counter to misread.
  mine="$RUN_DIR/${prefix}${now}.$$.${RANDOM}${RANDOM}"
  ( set -o noclobber; : > "$mine" ) 2>/dev/null || return 1
  # Count unexpired markers (mine included), pruning ones that have aged out. The
  # timestamp is read from the NAME, never the contents.
  for f in "$RUN_DIR/$prefix"*; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    ts="${base#"$prefix"}"; ts="${ts%%.*}"
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    if [ "$ts" -lt "$cutoff" ]; then rm -f "$f" 2>/dev/null || true; continue; fi
    n=$((n + 1))
  done
  # Over the cap: roll back my reservation and throttle.
  if [ "$n" -gt "$_SPAWN_MAX" ]; then
    rm -f "$mine" 2>/dev/null || true
    return 1
  fi
  return 0
}
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

  # Reset each tick: a mismatched-live bridge (bound to a stale thread/app-server)
  # sets these to its pid and the start token it had at that moment. We never kill
  # it from here; the token is how the guard before the spawn proves it is gone.
  need_kill=""; need_kill_token=""
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
      # A mismatched live bridge must be retired and rebound -- but NOT here.
      # Tearing down (kill + wiping the recorded pidfile/app-server/thread) before
      # the gates below would let a throttled or proof-less tick leave the binding
      # wiped and un-rewritten, so a later launcher has nothing to rebind from
      # (#350). Defer every teardown to the point we are actually committed to
      # replacement -- and we do not kill it directly at all (below).
      need_kill="$bridge_pid"
      need_kill_token="$(_start_token "$bridge_pid" 2>/dev/null || true)"
    fi
  fi

  # Bound the spawn rate first (a rate-limited tick changes nothing), then reap
  # any orphan for this exact (project, role) so exactly one bridge remains. If a
  # reaped bridge will not exit, do not spawn beside it this tick.
  # In a set +e subshell: these two do a lot of probing whose non-zero results
  # (no such process, an empty match, a lock already held) are normal, and the
  # launcher runs under set -euo pipefail where a bare non-zero would exit it.
  # Either returning non-zero means "not this tick" -- and because no teardown has
  # run yet, the existing binding is left intact for the next tick / a rebind.
  if ! ( set +e; _spawn_rate_ok ); then
    poll_sleep
    continue
  fi
  if ! ( set +e; _reap_orphan_bridges ); then
    poll_sleep
    continue
  fi

  # A mismatched-live bridge must be proven GONE before we spawn its replacement,
  # or we double-start a writer that still holds the thread through async shutdown
  # (#935). We do NOT kill it from here (the pidfile is a bare pid with no identity,
  # so any direct kill could hit a reused pid; the lease-based reaper above is the
  # only reuse-safe path that may signal it). And we do NOT ask _agmsg_pid_alive to
  # "confirm" it is gone: a false from that helper can be a transient ps failure
  # (#954), and a failed observation is not proof (see THE RULE above). The one
  # positive proof we accept is the start token we stashed at detection now reading
  # a DIFFERENT process -- the old pid has been reused, so the old writer is gone.
  # A token that still matches (alive), or cannot be read (unproven), keeps the
  # binding and retries; a normal exit is picked up next tick by the dead-pid path
  # at the top of the loop. A lease-less bridge that never dies simply lingers
  # (orphan survival is acceptable; a wrong-kill or a double-start is not).
  if [ -n "$need_kill" ]; then
    _nk_now="$(_start_token "$need_kill" 2>/dev/null || true)"
    if [ -z "$need_kill_token" ] || [ -z "$_nk_now" ] || [ "$_nk_now" = "$need_kill_token" ]; then
      poll_sleep
      continue
    fi
  fi
  # Committed to spawning now: clear the stale records immediately before writing
  # the new ones, so no gate can bail out between the wipe and the rewrite.
  rm -f "$pidfile" "$appserver_file" "$thread_file"

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
