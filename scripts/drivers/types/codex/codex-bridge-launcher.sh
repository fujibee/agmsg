#!/usr/bin/env bash
set -euo pipefail

# Runs outside Codex's tool sandbox and owns the app-server connection. One
# bridge subscribes to every unpinned codex identity in this project.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
PROJECT_HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"
REQUEST_FILE="$RUN_DIR/codex-bridge-request.$PROJECT_HASH"

# shellcheck source=../../../lib/node.sh
source "$SCRIPT_DIR/../../../lib/node.sh"
NODE_BIN="$(agmsg_resolve_node)"
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

resolve_identity() {  # prints "team<TAB>name" lines for the project's codex roles
  "$SCRIPT_DIR/../../../identities.sh" "$PROJECT" "$TYPE" 2>/dev/null \
    | awk -v t="$TAB" 'NF >= 2 { print $1 t $2 }' \
    | sort -u
}

# Any change here can change the safe subscription set. Include the request
# thread plus each role's recorded session/project, not merely registrations:
# actas/resume rewrites a role record without changing identities.sh output.
safety_fingerprint() {
  local request="" team name rec rec_project
  [ -f "$REQUEST_FILE" ] && request="$(cat "$REQUEST_FILE" 2>/dev/null || true)"
  printf 'request=%s\n' "$request"
  resolve_identity | while IFS="$TAB" read -r team name; do
    rec="$(agmsg_role_session_uuid "$team" "$name" 2>/dev/null || true)"
    rec_project="$(agmsg_role_session_get "$team" "$name" project 2>/dev/null || true)"
    printf '%s\t%s\t%s\t%s\n' "$team" "$name" "$rec" "$rec_project"
  done
}

# actas may register the role a moment after launch, so retry while the parent
# (codex-monitor.sh) is alive. Multiple identities are intentional (#150).
ids=""
while kill -0 "$PARENT_PID" 2>/dev/null; do
  ids="$(resolve_identity || true)"
  [ -n "$ids" ] && break
  sleep 0.3
done
[ -n "$ids" ] || exit 0
safety_state="$(safety_fingerprint)"

# Safety over delivery (#150): a role-session record identifies the thread that
# owns a role. Never inject that role's inbox into a different live TUI. Roles
# without a record may share the current project TUI. If the hook could not
# provide a concrete live thread (`loaded`), recorded roles are conservatively
# left unsubscribed rather than guessed. They remain unread for their proper
# next SessionStart.
thread_hint="loaded"
if [ -f "$REQUEST_FILE" ]; then
  request="$(cat "$REQUEST_FILE" 2>/dev/null || true)"
  if [ -n "$request" ]; then
    IFS="$TAB" read -r _hint_type _hint_thread _hint_app <<EOF
$request
EOF
    [ -n "${_hint_thread:-}" ] && thread_hint="$_hint_thread"
  fi
fi
safe_ids=""
raw_identity_count="$(printf '%s\n' "$ids" | grep -c . || true)"
while IFS="$TAB" read -r candidate_team candidate_name; do
  [ -n "$candidate_team" ] || continue
  candidate_thread="$(agmsg_role_session_uuid "$candidate_team" "$candidate_name" 2>/dev/null || true)"
  if [ -n "$candidate_thread" ]; then
    candidate_project="$(agmsg_role_session_get "$candidate_team" "$candidate_name" project 2>/dev/null || true)"
    candidate_project_phys="$(agmsg_canonical_path "$candidate_project" 2>/dev/null || printf '%s' "$candidate_project")"
    # A record for another project proves this role's current seat is elsewhere:
    # never consume its unread rows from this project. A lone same-project role keeps #350's legacy recorded-thread affinity even
    # before a concrete request thread is available; multiplexed roles require
    # proof and are excluded while the hint is only `loaded`.
    if [ "$candidate_project_phys" != "$PROJECT_PHYS" ] \
       || { { [ "$thread_hint" = "loaded" ] && [ "$raw_identity_count" != "1" ]; } \
            || { [ "$thread_hint" != "loaded" ] && [ "$candidate_thread" != "$thread_hint" ]; }; }; then
      continue
    fi
  fi
  safe_ids="${safe_ids:+$safe_ids$'\n'}${candidate_team}"$'\t'"${candidate_name}"
done <<< "$ids"
ids="$safe_ids"
# A role record may be written by actas later in this same first turn. An empty
# safe set is therefore transient, not terminal: retry while the parent lives.
if [ -z "$ids" ]; then
  kill -0 "$PARENT_PID" 2>/dev/null || exit 0
  sleep 0.3
  exec "$0" "$TYPE" "$PROJECT" "$APP_SERVER" "$PARENT_PID"
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

while kill -0 "$PARENT_PID" 2>/dev/null; do
  # actas can join a second role after SessionStart. Re-exec through the same
  # safety filter when the registration set changes, replacing the old bridge
  # so the new role is actually subscribed instead of being stranded.
  latest_state="$(safety_fingerprint)"
  if [ "$latest_state" != "$safety_state" ]; then
    if [ -f "$pidfile" ]; then
      old_pid="$(cat "$pidfile" 2>/dev/null || true)"
      [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null || true
    fi
    exec "$0" "$TYPE" "$PROJECT" "$APP_SERVER" "$PARENT_PID"
  fi
  # Resolve the app-server URL (and thread) this iteration would launch against
  # FIRST, so the reuse check can compare a live bridge's bound server with the
  # current one. Thread source: a request file (older-codex hook) wins; otherwise
  # discover the live TUI thread via thread/loaded/list.
  thread_id="loaded"
  req_app_server="$APP_SERVER"
  if [ -f "$REQUEST_FILE" ]; then
    request="$(cat "$REQUEST_FILE" 2>/dev/null || true)"
    if [ -n "$request" ]; then
      IFS="$TAB" read -r _rtype _rthread _rapp <<EOF
$request
EOF
      [ -n "${_rthread:-}" ] && thread_id="$_rthread"
      [ -n "${_rapp:-}" ] && req_app_server="$_rapp"
    fi
  fi

  # With exactly one identity, preserve #350's role-session thread affinity.
  # Multiple identities are multiplexed into the active project thread; a role
  # that has a recorded thread is handled by its own future launcher pass rather
  # than being silently mapped to another role's recorded thread.
  # thread is whichever conversation the server last touched -- ambiguous when a
  # cwd has run more than one codex thread, so a co-resident thread can capture
  # this role's messages. The role-session record (#339) stores this role's own
  # thread deterministically; use it when present AND recorded for THIS project.
  # A request-file thread (above) still wins; roles with no record fall back to
  # "loaded". A foreign-project record was filtered out before launch (#150).
  # Freshness holds because a role re-runs actas on resume (#339), which
  # rewrites the record with its current thread.
  if [ "$thread_id" = "loaded" ] && [ "$(printf '%s\n' "$ids" | grep -c . || true)" = "1" ]; then
    IFS="$TAB" read -r team name <<EOF
$ids
EOF
    rec_thread="$(agmsg_role_session_uuid "$team" "$name" 2>/dev/null || true)"
    if [ -n "$rec_thread" ]; then
      rec_project="$(agmsg_role_session_get "$team" "$name" project 2>/dev/null || true)"
      rec_project_phys="$(agmsg_canonical_path "$rec_project" 2>/dev/null || printf '%s' "$rec_project")"
      [ "$rec_project_phys" = "$PROJECT_PHYS" ] && thread_id="$rec_thread"
    fi
  fi

  if [ -f "$pidfile" ]; then
    bridge_pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" 2>/dev/null; then
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
      bound_url="$(cat "$appserver_file" 2>/dev/null || true)"
      bound_thread="$(cat "$thread_file" 2>/dev/null || true)"
      if [ "$bound_url" = "$req_app_server" ] && [ "$bound_thread" = "$thread_id" ]; then
        sleep 0.3
        continue
      fi
      kill "$bridge_pid" 2>/dev/null || true
      rm -f "$pidfile" "$appserver_file" "$thread_file"
    fi
  fi

  nohup "${bridge_run[@]}" \
    --project "$PROJECT" \
    --type "$TYPE" \
    "${bridge_pairs[@]}" \
    --thread "$thread_id" \
    --app-server "$req_app_server" \
    --inline-inbox \
    >>"$log" 2>&1 &
  # Record what this bridge is bound to so a later launcher can detect staleness.
  printf '%s' "$req_app_server" > "$appserver_file"
  printf '%s' "$thread_id" > "$thread_file"
  sleep 1
done
