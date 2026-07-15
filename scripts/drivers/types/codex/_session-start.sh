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

# Resolve the current Codex thread id. Current Codex command hooks provide the
# authoritative id as the common stdin `session_id` field (parsed by the shared
# session-start.sh before this plug runs). CODEX_THREAD_ID is retained as a
# compatibility source; rollout lookup is legacy-only and never authoritative
# for launcher mode because another same-cwd TUI may own the newest rollout.
agmsg_resolve_codex_thread() {
  local project="$1"
  if [ -n "${CODEX_THREAD_ID:-}" ]; then
    printf '%s' "$CODEX_THREAD_ID"
    return 0
  fi
  if [ -n "${HOOK_SESSION_ID:-}" ]; then
    printf '%s' "$HOOK_SESSION_ID"
    return 0
  fi
  # A rollout from the same cwd is not proof that it belongs to THIS remote
  # TUI.  The launcher can ask the shared app-server for its loaded set, so in
  # launcher mode never turn an old rollout into an authoritative route.
  [ "${AGMSG_CODEX_BRIDGE_LAUNCHER:-}" = "1" ] && return 0
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
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/codex-lease.sh"
  if [ -n "${CODEX_THREAD_ID:-}" ] && [ -n "${HOOK_SESSION_ID:-}" ] \
    && [ "$CODEX_THREAD_ID" != "$HOOK_SESSION_ID" ]; then
    [ -n "${AGMSG_CODEX_MONITOR_STATE_FILE:-}" ] \
      && codex_monitor_state_write "$AGMSG_CODEX_MONITOR_STATE_FILE" route_identity_conflict
    exit 0
  fi
  thread_id="$(agmsg_resolve_codex_thread "$PROJECT")"
  launcher_mode=0
  managed_appserver_hook=0
  existing_monitor_route=0
  request_file="${AGMSG_CODEX_BRIDGE_REQUEST_FILE:-}"
  tui_generation="${AGMSG_CODEX_TUI_GENERATION:-}"
  state_file="${AGMSG_CODEX_MONITOR_STATE_FILE:-}"
  pending_file=""
  contract_team=""
  contract_name=""
  app_server="${AGMSG_CODEX_BRIDGE_APP_SERVER:-}"
  if [ "${AGMSG_CODEX_BRIDGE_LAUNCHER:-}" = 1 ]; then
    launcher_mode=1
  elif [ -n "${AGMSG_CODEX_APP_SERVER_GENERATION:-}" ] \
    && [ -n "${AGMSG_CODEX_APP_SERVER_PROJECT_HASH:-}" ]; then
    # In remote mode hooks run under the shared app-server, not under the TUI,
    # so they cannot inherit the TUI-generation environment. The managed
    # app-server supplies only its own generation/project proof. Resolve a TUI
    # contract only when exactly one fresh, live pending generation exists.
    managed_appserver_hook=1
    project_hash="$(printf '%s' "$PROJECT" | agmsg_sha1)"
    if [ "$project_hash" = "$AGMSG_CODEX_APP_SERVER_PROJECT_HASH" ]; then
      record="$(codex_appserver_record_path "$project_hash")"
      record_port="$(codex_lease_field "$record" port 2>/dev/null || true)"
      case "$record_port" in
        ''|*[!0-9]*) app_server="" ;;
        *) app_server="ws://127.0.0.1:$record_port" ;;
      esac
      if [ -n "$thread_id" ] && [ -n "$app_server" ] \
        && codex_monitor_thread_has_fresh_lease "$PROJECT" "$thread_id" "$app_server"; then
        existing_monitor_route=1
      else
        pending_candidates="$(codex_monitor_pending_candidates "$project_hash" "$PROJECT" \
          "$AGMSG_CODEX_APP_SERVER_GENERATION")"
        pending_count="$(printf '%s\n' "$pending_candidates" | awk 'NF { c++ } END { print c + 0 }')"
        if [ "$pending_count" = 1 ]; then
          IFS=$'\t' read -r pending_file tui_generation request_file state_file app_server contract_team contract_name <<EOF
$pending_candidates
EOF
          launcher_mode=1
        elif [ "$pending_count" -gt 1 ]; then
          while IFS=$'\t' read -r _pending _generation _request candidate_state _rest; do
            [ -n "$candidate_state" ] \
              && codex_monitor_state_write "$candidate_state" request_ambiguous multiple_waiting_tuis
          done <<EOF
$pending_candidates
EOF
        fi
      fi
    fi
  fi
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
  if [ -z "$app_server" ]; then
    [ -n "${AGMSG_CODEX_MONITOR_STATE_FILE:-}" ] \
      && codex_monitor_state_write "$AGMSG_CODEX_MONITOR_STATE_FILE" app_server_missing
    exit 0
  fi

  pair_count=$(printf '%s\n' "$PAIRS" | awk 'NF >= 2 { c++ } END { print c + 0 }')
  team="${AGMSG_CODEX_TEAM:-$contract_team}"
  name="${AGMSG_CODEX_NAME:-$contract_name}"
  if [ -n "$team" ] || [ -n "$name" ]; then
    if [ -z "$team" ] || [ -z "$name" ] \
      || { [ -n "$PAIRS" ] \
        && ! printf '%s\n' "$PAIRS" | grep -Fxq "$(printf '%s\t%s' "$team" "$name")"; } \
      || { [ -z "$PAIRS" ] && [ "$launcher_mode" != 1 ]; }; then
      [ -n "${AGMSG_CODEX_MONITOR_STATE_FILE:-}" ] \
        && codex_monitor_state_write "$AGMSG_CODEX_MONITOR_STATE_FILE" identity_invalid
      exit 0
    fi
  elif [ -n "$thread_id" ]; then
    role_record="$(agmsg_role_session_lookup_unique_by_sid "$thread_id" 2>/dev/null || true)"
    role_team=$(printf '%s\n' "$role_record" | sed -n 's/^team=//p' | head -1)
    role_name=$(printf '%s\n' "$role_record" | sed -n 's/^agent=//p' | head -1)
    if [ -n "$role_team" ] && [ -n "$role_name" ] \
      && printf '%s\n' "$PAIRS" | grep -Fxq "$(printf '%s\t%s' "$role_team" "$role_name")"; then
      team="$role_team"; name="$role_name"
    fi
  fi
  if [ -z "$team" ] || [ -z "$name" ]; then
    if [ "$pair_count" = "1" ]; then
      IFS=$'\t' read -r team name <<EOF
$(printf '%s\n' "$PAIRS" | awk 'NF >= 2 { print; exit }')
EOF
    else
      [ -n "${AGMSG_CODEX_MONITOR_STATE_FILE:-}" ] \
        && codex_monitor_state_write "$AGMSG_CODEX_MONITOR_STATE_FILE" identity_ambiguous
      exit 0
    fi
  fi
  [ -n "$team" ] && [ -n "$name" ] || exit 0

  # The hook's session_id (or matching compatibility env) is authoritative for
  # this live seat. Persist it now so a later resume cannot inherit an older
  # same-cwd rollout merely because it was the only file on disk.
  if [ -n "$thread_id" ] && { [ -n "${HOOK_SESSION_ID:-}" ] || [ -n "${CODEX_THREAD_ID:-}" ]; }; then
    agmsg_role_session_reassign "$team" "$name" "$thread_id" "$PROJECT" codex 2>/dev/null || true
  fi

  [ "$existing_monitor_route" = 1 ] && exit 0
  # A hook proven to belong to an agmsg-managed app-server must never fall back
  # to legacy bridge startup when no unique pending TUI can be proven.
  [ "$managed_appserver_hook" = 1 ] && [ "$launcher_mode" = 0 ] && exit 0

  if [ "$launcher_mode" = "1" ]; then
    if [ -z "$thread_id" ]; then
      [ -n "$state_file" ] \
        && codex_monitor_state_write "$state_file" waiting_thread loaded_fallback
      exit 0
    fi
    if [ -z "$request_file" ] || [ -z "$tui_generation" ]; then
      [ -n "$state_file" ] \
        && codex_monitor_state_write "$state_file" request_contract_missing
      exit 0
    fi
    {
      printf 'format_version=2\n'
      printf 'generation=%s\ntype=%s\nteam=%s\nname=%s\n' "$tui_generation" "$TYPE" "$team" "$name"
      printf 'thread=%s\napp_server=%s\nproject=%s\n' "$thread_id" "$app_server" "$PROJECT"
      printf 'created_at=%s\n' "$(date +%s)"
    } | codex_lease_atomic_write "$request_file"
    [ -n "$state_file" ] \
      && codex_monitor_state_write "$state_file" request_published exact_thread
    exit 0
  fi

  mkdir -p "$RUN_DIR" 2>/dev/null || true
  pidfile="$RUN_DIR/codex-bridge.$team.$name.pid"
  if [ -f "$pidfile" ]; then
    bridge_pid=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" 2>/dev/null; then
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
