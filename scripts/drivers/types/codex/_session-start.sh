#!/usr/bin/env bash
# codex SessionStart plug — hand the session off to the Codex bridge.
#
# Sourced by session-start.sh in its global context (so it sees TYPE, PROJECT,
# RUN_DIR, SKILL_DIR, SCRIPT_DIR, PAIRS and the helpers agmsg_sha1,
# agmsg_sqlite_mem, agmsg_resolve_node, agmsg_canonical_path, agmsg_agent_pid).
# Defines agmsg_session_start, overriding session-start.sh's default no-op.
#
# Codex has no Monitor tool. When launched through codex-monitor.sh, the TUI is
# attached to a shared app-server. Hand the bridge off so incoming agmsg rows
# become turns in the current Codex thread without exposing socket/thread
# plumbing to the user. With AGMSG_CODEX_BRIDGE_LAUNCHER=1 (set by
# codex-monitor.sh) we only write a request file and let the out-of-sandbox
# launcher start the bridge — a hook-launched bridge cannot connect to the unix
# socket from inside the Codex sandbox (#41).

# Resolve the current Codex thread id. CODEX_THREAD_ID is only exported on the
# interactive --remote path; fresh and `codex exec` sessions never export it, so
# fall back to the newest rollout file whose session_meta cwd matches the
# project. Codex writes that rollout ~1s before SessionStart, so it is already
# present; a short bounded retry covers the race if it is not. See #41.
agmsg_resolve_codex_thread() {
  local project="$1"
  if [ -n "${CODEX_THREAD_ID:-}" ]; then
    printf '%s' "$CODEX_THREAD_ID"
    return 0
  fi
  local sessions_dir="$HOME/.codex/sessions"
  [ -d "$sessions_dir" ] || return 0
  # Compare PHYSICAL paths. agmsg may open the project via a symlinked/logical
  # path (e.g. a workspace under a symlinked home) while Codex records the
  # canonical cwd in session_meta. A raw string compare then misses every
  # rollout, so the thread is never resolved and the bridge never starts. See
  # #160. Canonicalize the project once; canonicalize each rollout cwd per row.
  local project_phys
  project_phys=$(agmsg_canonical_path "$project")
  local waited=0 f first esc cwd cwd_phys tid
  while :; do
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      first=$(head -1 "$f" 2>/dev/null)
      case "$first" in *'"session_meta"'*) ;; *) continue ;; esac
      esc=$(printf '%s' "$first" | sed "s/'/''/g")
      cwd=$(agmsg_sqlite_mem "SELECT COALESCE(json_extract('$esc','\$.payload.cwd'),'')" 2>/dev/null)
      cwd_phys=$(agmsg_canonical_path "$cwd")
      [ "$cwd_phys" = "$project_phys" ] || continue
      tid=$(agmsg_sqlite_mem "SELECT COALESCE(json_extract('$esc','\$.payload.id'),'')" 2>/dev/null)
      if [ -n "$tid" ]; then
        printf '%s' "$tid"
        return 0
      fi
    done <<INNER_EOF
$(ls -t "$sessions_dir"/*/*/*/rollout-*.jsonl 2>/dev/null | head -20)
INNER_EOF
    [ "$waited" -ge 2 ] && break
    waited=$((waited + 1))
    sleep 1
  done
  return 0
}

agmsg_session_start() {
  thread_id="$(agmsg_resolve_codex_thread "$PROJECT")"
  [ -n "$thread_id" ] || exit 0
  app_server="${AGMSG_CODEX_BRIDGE_APP_SERVER:-}"
  if [ -z "$app_server" ]; then
    agent_pid=$(agmsg_agent_pid "$TYPE" 2>/dev/null || true)
    if [ -n "$agent_pid" ]; then
      agent_cmd=$(compat_get_cmdline "$agent_pid" 2>/dev/null || true)
      app_server=$(printf '%s\n' "$agent_cmd" \
        | sed -n 's/.*\(unix:\/\/[^[:space:]]*\).*/\1/p' \
        | head -1)
    fi
  fi
  if [ -z "$app_server" ]; then
    project_hash=$(printf '%s' "$PROJECT" | agmsg_sha1)
    socket_path="$RUN_DIR/codex-app-server.$project_hash.sock"
    if [ -S "$socket_path" ] || [ "${AGMSG_TEST_ASSUME_CODEX_SOCKET:-}" = "$socket_path" ]; then
      app_server="unix://$socket_path"
    fi
  fi
  [ -n "$app_server" ] || exit 0

  pair_count=$(printf '%s\n' "$PAIRS" | awk 'NF >= 2 { c++ } END { print c + 0 }')
  [ "$pair_count" = "1" ] || exit 0
  team=$(printf '%s\n' "$PAIRS" | awk 'NF >= 2 { print $1; exit }')
  name=$(printf '%s\n' "$PAIRS" | awk 'NF >= 2 { print $2; exit }')
  [ -n "$team" ] && [ -n "$name" ] || exit 0

  if [ "${AGMSG_CODEX_BRIDGE_LAUNCHER:-}" = "1" ]; then
    project_hash=$(printf '%s' "$PROJECT" | agmsg_sha1)
    request_file="$RUN_DIR/codex-bridge-request.$project_hash"
    tmp_request="$request_file.$$"
    mkdir -p "$RUN_DIR" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$TYPE" "$team" "$name" "$thread_id" "$app_server" > "$tmp_request"
    mv "$tmp_request" "$request_file"
    exit 0
  fi

  mkdir -p "$RUN_DIR" 2>/dev/null || true
  pidfile="$RUN_DIR/codex-bridge.$team.$name.pid"
  if [ -f "$pidfile" ]; then
    bridge_pid=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$bridge_pid" ] && compat_pid_alive "$bridge_pid"; then
      exit 0
    fi
  fi

  log="$RUN_DIR/codex-bridge.$team.$name.log"
  # An explicit AGMSG_CODEX_BRIDGE_CMD is a complete runnable (tests, custom
  # wrappers) — run it as-is. Only the default codex-bridge.js is launched
  # through a resolved Node, since its env-node shebang fails in shells where a
  # version-manager Node is not on PATH (#170).
  if [ -n "${AGMSG_CODEX_BRIDGE_CMD:-}" ]; then
    bridge_run=("$AGMSG_CODEX_BRIDGE_CMD")
  else
    bridge_run=("$(agmsg_resolve_node)" "$SKILL_DIR/scripts/drivers/types/codex/codex-bridge.js")
  fi
  nohup "${bridge_run[@]}" \
    --project "$PROJECT" \
    --type "$TYPE" \
    --team "$team" \
    --name "$name" \
    --thread "$thread_id" \
    --app-server "$app_server" \
    --inline-inbox \
    >>"$log" 2>&1 &
  exit 0
}
