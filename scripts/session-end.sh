#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# SessionEnd hook — symmetric counterpart of session-start.sh.
#
# Usage: session-end.sh <type> <project_path>
#
# When Claude Code terminates a session (matchers: clear / resume / logout /
# prompt_input_exit / bypass_permissions_disabled / other), this script:
#   1. Reads session_id from the hook input JSON on stdin.
#   2. Kills the watch.sh process for that session via its pidfile.
#   3. Removes the matching cc-instance.<cc_pid> file if it still points at
#      this session_id, so the next SessionStart starts cleanly.
#
# Cleanup is best-effort: any missing pieces just result in nothing to do.
# The script always exits 0 — SessionEnd cannot block session termination
# anyway, and a non-zero exit would only generate noise in logs.

TYPE="${1:?Usage: session-end.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

# Compatibility guard for legacy background-resume processes created before
# that transport was disabled. Their parent owns cleanup, so this hook must not
# change role state while an old process is still unwinding.
if [ "$TYPE" = "codex" ] && [ "${AGMSG_CODEX_BACKGROUND_RESUME:-}" = "1" ]; then
  exit 0
fi

# Drop project markers (#92) whose agent process has exited. Liveness-based, so
# a session that persists across /clear keeps its marker until the process dies.
agmsg_marker_gc_stale 2>/dev/null || true

INPUT=$(cat 2>/dev/null || true)
SESSION_ID=""
if [ -n "$INPUT" ]; then
  SESSION_ID=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)
fi
[ -z "$SESSION_ID" ] && exit 0

PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"

wait_for_codex_receiver_exit() {
  local pid="$1" check=0 state
  while [ "$check" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "$state" in Z*) return 0 ;; esac
    sleep 0.1
    check=$((check + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || return 1
    check=0
    while [ "$check" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
      state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
      case "$state" in Z*) return 0 ;; esac
      sleep 0.1
      check=$((check + 1))
    done
  fi
  ! kill -0 "$pid" 2>/dev/null
}

stop_codex_thread_receivers() {
  local meta base kind pidfile pid cmd meta_project meta_type meta_thread team name
  local label plist domain check chat
  for meta in "$RUN_DIR"/codex-bridge.*.meta "$RUN_DIR"/codex-app-monitor.*.meta; do
    [ -f "$meta" ] || continue
    meta_project="$(sed -n 's/^project=//p' "$meta" | head -1)"
    meta_type="$(sed -n 's/^type=//p' "$meta" | head -1)"
    meta_thread="$(sed -n 's/^thread=//p' "$meta" | head -1)"
    [ "$(agmsg_canonical_path "$meta_project")" = "$(agmsg_canonical_path "$PROJECT")" ] || continue
    [ "$meta_type" = "$TYPE" ] || continue
    [ "$meta_thread" = "$SESSION_ID" ] || continue

    base="${meta%.meta}"
    kind="${base##*/}"
    pidfile="$base.pid"
    plist="$base.plist"
    label="$(sed -n 's/^launch_label=//p' "$meta" | head -1)"
    if [ -z "$label" ] && [ -f "$plist" ]; then
      label="$(awk '/<key>Label<\/key>/{getline; sub(/^[[:space:]]*<string>/, ""); sub(/<\/string>[[:space:]]*$/, ""); print; exit}' "$plist")"
    fi
    if [ -n "$label" ] && command -v launchctl >/dev/null 2>&1; then
      domain="gui/$(id -u)"
      launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
      check=0
      while [ "$check" -lt 20 ] && launchctl print "$domain/$label" >/dev/null 2>&1; do
        sleep 0.1
        check=$((check + 1))
      done
    fi

    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
      case "$kind:$cmd" in
        codex-bridge.*:*codex-bridge.js*|codex-app-monitor.*:*codex-app-monitor.sh*)
          kill "$pid" 2>/dev/null || true
          if ! wait_for_codex_receiver_exit "$pid"; then
            echo "session-end: Codex receiver pid $pid did not stop; preserving its run files" >&2
            continue
          fi
          ;;
      esac
    fi

    team="$(sed -n 's/^team=//p' "$meta" | head -1)"
    name="$(sed -n 's/^name=//p' "$meta" | head -1)"
    rm -f "$pidfile" "$meta" "$base.appserver" "$base.log" "$plist" \
      "$base.health" "$base.preflight.log" "$base.last-prompt.txt" \
      "$base.last-message.txt" "$base.last-status" "$base.last-ids" \
      "$base.watch-output"
    if [ -n "$team" ] && [ -n "$name" ]; then
      rm -f "$RUN_DIR/codex-chat-visible.$team.$name.meta"
    fi
  done

  for chat in "$RUN_DIR"/codex-chat-visible.*.meta; do
    [ -f "$chat" ] || continue
    meta_project="$(sed -n 's/^project=//p' "$chat" | head -1)"
    meta_type="$(sed -n 's/^type=//p' "$chat" | head -1)"
    meta_thread="$(sed -n 's/^thread=//p' "$chat" | head -1)"
    if [ "$(agmsg_canonical_path "$meta_project")" = "$(agmsg_canonical_path "$PROJECT")" ] \
        && [ "$meta_type" = "$TYPE" ] && [ "$meta_thread" = "$SESSION_ID" ]; then
      rm -f "$chat"
    fi
  done
}

# Re-derive the per-process instance id this session's watcher/locks are keyed
# under (#93). The enclosing agent process is still alive during the hook, so
# agmsg_instance_id normally resolves the same "<sid>.<pid>" that session-start
# computed — cleaning ONLY this process's state, never a sibling --continue/
# --resume process that shares the bare session_id. If the pid can't be
# resolved we fall back to the bare session_id (and clean only the bare-keyed
# artifacts); we deliberately do NOT glob-delete "<sid>.*", which would kill a
# living sibling — those are left to session-start's liveness GC instead.
INSTANCE_ID="$(agmsg_instance_id "$SESSION_ID" "$TYPE")"

PIDFILE="$RUN_DIR/watch.$INSTANCE_ID.pid"
if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # Defensive: only kill if the pid's command line still looks like our
    # watch.sh. Pids can be recycled — a stale pidfile could point at an
    # unrelated process that took the same pid.
    cmd=$(compat_get_cmdline "$pid" 2>/dev/null || true)
    case "$cmd" in
      *"$SKILL_DIR/scripts/watch.sh"*) kill "$pid" 2>/dev/null || true ;;
      *) ;;
    esac
  fi
  rm -f "$PIDFILE"
fi

# Drop the per-session stream watermark (see #107) — the session is ending, so
# there is no restart to resume; a future session_id reuse should start fresh.
rm -f "$RUN_DIR/watch.$INSTANCE_ID.watermark" 2>/dev/null || true

# Clean the cc-instance entry that points at this instance id. The enclosing
# CC process may itself be exiting (matcher=logout/etc.), in which case its
# cc-instance.<pid> file would otherwise be left stale. A sibling process that
# shares the bare session_id stores a different instance id, so it is untouched.
for f in "$RUN_DIR"/cc-instance.*; do
  [ -f "$f" ] || continue
  state=$(cat "$f" 2>/dev/null || true)
  [ "$state" = "$INSTANCE_ID" ] && rm -f "$f"
done

# Release any actas exclusivity locks owned by this instance so peers can
# reclaim those identities on their next watcher cycle. Keyed by instance id so
# a sibling resume process's locks are not released out from under it. See #62.
actas_lock_release_all "$INSTANCE_ID" 2>/dev/null || true

# A Codex Desktop heartbeat/watchdog must not keep waking a thread after its
# session ends. Keep an inactive tombstone so the independent watchdog can read
# the automation ids and delete both scheduled jobs on its next run.
if [ "$TYPE" = "codex" ]; then
  stop_codex_thread_receivers
  "$SCRIPT_DIR/drivers/types/codex/codex-monitor-lease.sh" \
    deactivate-thread "$PROJECT" "$SESSION_ID" >/dev/null 2>&1 || true
fi

exit 0
