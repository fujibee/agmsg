#!/usr/bin/env bash
# codex delivery plug.
#
# codex keeps the default JSON event-hooks apply (agmsg_delivery_apply); it adds
# enable/disable side effects (print the monitor shim setup on enable, stop the
# bridge on disable) and replaces the runtime status summary with Codex bridge
# liveness. Sourced into delivery.sh's context, so SKILL_DIR, SCRIPT_DIR,
# RUN_DIR, agmsg_resolve_node, CODEX_MONITOR_DOC_URL and stop_codex_bridge are
# in scope.
# Args (both hooks): on_enable <mode> <type> <project>; on_disable <type> <project>.

agmsg_delivery_on_enable() {
  local project="$3" project_hash project_phys
  mkdir -p "$RUN_DIR"
  project_phys="$(agmsg_canonical_path "$project" 2>/dev/null || printf '%s' "$project")"
  project_hash="$(printf '%s' "$project_phys" | agmsg_sha1 2>/dev/null || true)"
  [ -n "$project_hash" ] && rm -f "$RUN_DIR/codex-monitor-disabled.$project_hash"
  echo "Codex monitor beta is enabled."
  echo "Add this shell function to your interactive shell profile, then restart the shell:"
  if "$SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh" function; then
    echo "Future Codex sessions: launch with codex. In monitor-mode projects, the agmsg function routes interactive Codex sessions through the bridge."
    echo "Optional global PATH shim is still available with:"
    echo "  $SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh install"
  else
    echo "Codex monitor mode is enabled, but the codex shell function could not be printed."
    echo "Future Codex sessions: launch with $SKILL_DIR/scripts/drivers/types/codex/codex-monitor.sh, or resolve the setup issue above."
  fi
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      echo "PowerShell profile alternative (uses Git Bash explicitly, not WSL):"
      "$SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh" powershell-function || true
      ;;
  esac
  # Node preflight: the bridge (codex-bridge.js) is a Node program, so without
  # Node it silently never starts — flag it at enable time. Resolve via the same
  # path the runtime uses (lib/node.sh). AGMSG_NODE / AGMSG_CODEX_NODE override.
  local codex_node
  codex_node="$(agmsg_resolve_node)"
  if ! command -v "$codex_node" >/dev/null 2>&1 && [ ! -x "$codex_node" ]; then
    echo "WARNING: Node.js ('$codex_node') was not found. The Codex bridge needs Node —"
    echo "  monitor delivery will NOT start until Node is installed (or set AGMSG_NODE)."
  fi
  echo "Restart your Codex session (quit and relaunch \`codex\`). The launcher starts"
  echo "  with the TUI; the first turn lets SessionStart publish its exact session/thread id."
  echo "  Already-running sessions stay unmonitored until they restart."
  echo "For more info: $CODEX_MONITOR_DOC_URL"
}

agmsg_delivery_on_disable() {
  local project="$2"
  local stopped project_hash project_phys
  mkdir -p "$RUN_DIR"
  project_phys="$(agmsg_canonical_path "$project" 2>/dev/null || printf '%s' "$project")"
  project_hash="$(printf '%s' "$project_phys" | agmsg_sha1 2>/dev/null || true)"
  # Stop the owning launcher loop before killing its bridge, otherwise a live
  # TUI immediately recreates the bridge on the next 300ms iteration.
  [ -n "$project_hash" ] && : >"$RUN_DIR/codex-monitor-disabled.$project_hash"
  stopped=$(stop_codex_bridge "$project")
  if [ "${stopped:-0}" -gt 0 ]; then
    echo "Stopped $stopped Codex bridge process(es) for this project and cleaned their run files."
  fi
  echo "Note: shell profile functions are not changed automatically."
  echo "  If you installed the optional global shim and no other project uses monitor mode, remove it:"
  echo "    $SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh remove"
  echo "    # then drop any agmsg Codex function or ~/.agents/bin PATH entry you added for monitor"
}

agmsg_delivery_runtime_status() {
  local type="$1" project="$2"
  local pairs found=0 project_phys project_hash state_reported=0
  project_phys="$(agmsg_canonical_path "$project" 2>/dev/null || printf '%s' "$project")"
  project_hash="$(printf '%s' "$project_phys" | agmsg_sha1 2>/dev/null || true)"
  pairs=$("$SCRIPT_DIR/identities.sh" "$project" "$type" 2>/dev/null || true)

  if [ -z "$pairs" ]; then
    echo "Codex bridge: no identities registered for this project"
    return 0
  fi

  while IFS=$'\t' read -r team name _rest; do
    if [ -z "$team" ] || [ -z "$name" ]; then
      continue
    fi
    found=1

    local base pidfile metafile pid meta_pid meta_project meta_project_norm meta_type meta_domain meta_ok project_norm pid_state
    base="$RUN_DIR/codex-bridge.$team.$name"
    pidfile="$base.pid"
    metafile="$base.meta"

    if [ ! -f "$pidfile" ]; then
      echo "Codex bridge: $team/$name not running"
      local latest_state state_phase state_detail
      latest_state="$(ls -t "$RUN_DIR"/codex-monitor-state."$project_hash".* 2>/dev/null | head -1 || true)"
      if [ -n "$latest_state" ] && [ "$state_reported" -eq 0 ]; then
        state_phase="$(codex_lease_field "$latest_state" phase 2>/dev/null || true)"
        state_detail="$(codex_lease_field "$latest_state" detail 2>/dev/null || true)"
        [ -n "$state_phase" ] && echo "Codex monitor (project): $state_phase${state_detail:+ ($state_detail)}"
        state_reported=1
      fi
      continue
    fi

    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [ -z "$pid" ]; then
      echo "Codex bridge: $team/$name stale pidfile (empty pid)"
      continue
    fi

    if [ ! -f "$metafile" ]; then
      echo "Codex bridge: $team/$name stale pidfile (missing metadata)"
      continue
    fi

    meta_ok=1
    meta_pid=$(awk -F= '/^pid=/{sub(/^pid=/, ""); print; exit}' "$metafile" 2>/dev/null || true)
    meta_project=$(awk -F= '/^project=/{sub(/^project=/, ""); print; exit}' "$metafile" 2>/dev/null || true)
    meta_type=$(awk -F= '/^type=/{sub(/^type=/, ""); print; exit}' "$metafile" 2>/dev/null || true)
    meta_domain=$(awk -F= '/^pid_domain=/{sub(/^pid_domain=/, ""); print; exit}' "$metafile" 2>/dev/null || true)
    [ -n "$meta_pid" ] && [ "$meta_pid" != "$pid" ] && meta_ok=0
    if [ -n "$meta_project" ]; then
      # The native Windows bridge records E:\path while delivery.sh commonly
      # resolves the same project as /e/path or E:/path. Compare normalized
      # spellings so a healthy bridge is not reported as a stale mismatch.
      meta_project_norm=$(agmsg_normalize_project_path "$meta_project" 2>/dev/null || printf '%s' "$meta_project")
      project_norm=$(agmsg_normalize_project_path "$project" 2>/dev/null || printf '%s' "$project")
      [ "$meta_project_norm" != "$project_norm" ] && meta_ok=0
    fi
    [ -n "$meta_type" ] && [ "$meta_type" != "$type" ] && meta_ok=0
    if [ "$meta_ok" -ne 1 ]; then
      echo "Codex bridge: $team/$name stale pidfile (metadata mismatch)"
      continue
    fi

    case "$meta_domain" in
      native) pid_state="$(compat_pid_state_native "$pid")" ;;
      msys) if compat_pid_alive_msys "$pid"; then pid_state=alive; else pid_state=dead; fi ;;
      *) if _agmsg_pid_alive "$pid"; then pid_state=alive; else pid_state=dead; fi ;;
    esac
    if [ "$pid_state" = unknown ]; then
      echo "Codex bridge: $team/$name liveness unknown (pid $pid; kept fail-closed)"
      continue
    fi
    if [ "$pid_state" = alive ]; then
      echo "Codex bridge: $team/$name alive (pid $pid)"
      local bridge_lease lease_updated lease_age now bound_generation bound_thread bound_server phase lease_pid
      local route_reason="" tui_ok=0 app_ok=0 app_record app_status app_pid app_domain app_port
      local app_creation current_app_creation app_cmd app_state
      bridge_lease="$(codex_bridge_lease_path "$team" "$name")"
      if [ ! -f "$bridge_lease" ]; then
        route_reason="missing bridge lease"
      else
        lease_pid="$(codex_lease_field "$bridge_lease" owner_winpid 2>/dev/null || true)"
        [ -n "$lease_pid" ] && [ "$lease_pid" != "$pid" ] && route_reason="bridge lease pid mismatch"
        lease_updated="$(codex_lease_field "$bridge_lease" updated_at 2>/dev/null || true)"
        now="$(date +%s)"
        case "$lease_updated" in
          ''|*[!0-9]*) route_reason="invalid bridge heartbeat" ;;
          *)
            lease_age=$((now - lease_updated))
            if [ "$lease_age" -lt 0 ] || [ "$lease_age" -gt "${AGMSG_CODEX_LEASE_TIMEOUT:-15}" ]; then
              route_reason="stale bridge heartbeat"
            fi
            ;;
        esac
        bound_generation="$(codex_lease_field "$bridge_lease" bound_generation 2>/dev/null || true)"
        bound_thread="$(codex_lease_field "$bridge_lease" bound_thread_id 2>/dev/null || true)"
        bound_server="$(codex_lease_field "$bridge_lease" app_server 2>/dev/null || true)"
        phase="$(codex_lease_field "$bridge_lease" phase 2>/dev/null || true)"
        if [ -z "$route_reason" ]; then
          if codex_tui_generation_fresh "$team" "$name" "$bound_generation"; then
            tui_ok=1
          else
            route_reason="no fresh matching TUI lease"
          fi
        fi
        if [ -z "$route_reason" ] && { [ -z "$bound_thread" ] || [ "$bound_thread" = loaded ]; }; then
          route_reason="thread not resolved"
        fi
        if [ -z "$route_reason" ] && [ "$phase" != watch_armed ] && [ "$phase" != delivering ]; then
          route_reason="bridge phase ${phase:-unknown}"
        fi
        app_record="$(codex_appserver_record_path "$project_hash")"
        app_status="$(codex_lease_field "$app_record" status 2>/dev/null || true)"
        app_pid="$(codex_lease_field "$app_record" pid 2>/dev/null || true)"
        app_domain="$(codex_lease_field "$app_record" pid_domain 2>/dev/null || true)"
        app_port="$(codex_lease_field "$app_record" port 2>/dev/null || true)"
        app_creation="$(codex_lease_field "$app_record" pid_creation 2>/dev/null || true)"
        app_state="$(codex_pid_state_domain "$app_domain" "$app_pid")"
        current_app_creation="$(codex_pid_creation_domain "$app_domain" "$app_pid" 2>/dev/null || true)"
        app_cmd="$(codex_pid_cmdline_domain "$app_domain" "$app_pid" 2>/dev/null || true)"
        if [ "$app_state" = unknown ] && [ -z "$route_reason" ]; then
          route_reason="app-server liveness unknown"
        elif [ "$app_status" = ready ] && [ -n "$app_pid" ] \
          && [ "$app_state" = alive ] \
          && { [ -z "$app_creation" ] || { [ -n "$current_app_creation" ] && [ "$app_creation" = "$current_app_creation" ]; }; } \
          && [ "$bound_server" = "ws://127.0.0.1:$app_port" ]; then
          case "$app_cmd" in *codex*app-server*) app_ok=1 ;; esac
        elif [ -z "$route_reason" ]; then
          route_reason="app-server not ready/alive"
        fi
        if [ "$app_ok" -ne 1 ] && [ -z "$route_reason" ]; then
          route_reason="app-server identity/route mismatch"
        fi
      fi
      if [ -z "$route_reason" ] && [ "$tui_ok" -eq 1 ] && [ "$app_ok" -eq 1 ]; then
        echo "Codex route: $team/$name healthy (thread $bound_thread, phase $phase)"
      else
        echo "Codex route: $team/$name degraded (${route_reason:-unknown health failure})"
      fi
    else
      echo "Codex bridge: $team/$name stale pidfile (pid $pid not running)"
    fi
  done <<< "$pairs"

  if [ "$found" -eq 0 ]; then
    echo "Codex bridge: no identities registered for this project"
  fi
}
