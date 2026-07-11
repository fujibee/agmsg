#!/usr/bin/env bash
# codex delivery plug.
#
# codex keeps the default JSON event-hooks apply (agmsg_delivery_apply); it adds
# enable/disable side effects (print the monitor shim setup on enable, stop the
# bridge on disable) and replaces the runtime status summary with Codex bridge
# liveness. Ordinary Codex.app fallback is chat-visible turn delivery; the
# legacy headless app monitor is opt-in only. Sourced into delivery.sh's context,
# so SKILL_DIR, SCRIPT_DIR, RUN_DIR, agmsg_resolve_node, CODEX_MONITOR_DOC_URL
# and stop_codex_bridge are in scope.
# Args (both hooks): on_enable <mode> <type> <project>; on_disable <type> <project>.

# Codex monitor mode always includes the visible Stop-hook fallback. The
# SessionStart hook preserves/rebinds the monitor after restart; the Stop hook
# is the safe path when no app-server can inject into the visible thread.
agmsg_delivery_apply() {
  local type="$1" project="$2" mode="$3"
  if [ "$mode" = "monitor" ]; then
    agmsg_delivery_apply_default "$type" "$project" both
  else
    agmsg_delivery_apply_default "$type" "$project" "$mode"
  fi
}

# `monitor` is the user-facing mode name even though Codex installs both hook
# types internally. Keep status stable for callers and existing automation.
agmsg_delivery_status() {
  agmsg_delivery_status_default "$@" | sed '1s/^mode: both$/mode: monitor/'
}

agmsg_delivery_on_enable() {
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
  # Node preflight: the bridge (codex-bridge.js) is a Node program, so without
  # Node it silently never starts — flag it at enable time. Resolve via the same
  # path the runtime uses (lib/node.sh). AGMSG_NODE / AGMSG_CODEX_NODE override.
  local codex_node
  codex_node="$(agmsg_resolve_node)"
  if ! command -v "$codex_node" >/dev/null 2>&1 && [ ! -x "$codex_node" ]; then
    echo "WARNING: Node.js ('$codex_node') was not found. The Codex bridge needs Node —"
    echo "  monitor delivery will NOT start until Node is installed (or set AGMSG_NODE)."
  fi
  echo "Restart your Codex session (quit and relaunch \`codex\`), then send your first"
  echo "  message — the bridge starts on your first turn, not the moment Codex opens."
  echo "  Already-running sessions stay unmonitored until they restart."
  echo "For more info: $CODEX_MONITOR_DOC_URL"
}

agmsg_delivery_on_disable() {
  local project="$2"
  local stopped
  stopped=$(stop_codex_bridge "$project")
  if [ "${stopped:-0}" -gt 0 ]; then
    echo "Stopped $stopped Codex bridge process(es) for this project and cleaned their run files."
  fi
  echo "Note: shell profile functions are not changed automatically."
  echo "  If you installed the optional global shim and no other project uses monitor mode, remove it:"
  echo "    $SKILL_DIR/scripts/drivers/types/codex/codex-shim-install.sh remove"
  echo "    # then drop any agmsg Codex function or ~/.agents/bin PATH entry you added for monitor"
}

agmsg_delivery_stop_directive() {
  local project="${PROJECT:-}"
  local mode="${MODE:-}"
  if [ "$mode" = "turn" ] && [ -n "$project" ]; then
    # The app monitor invokes `delivery.sh set turn` after repeated delivery
    # failures. Let that process finish writing fallback health and chat-visible
    # metadata before it exits on its own.
    if [ "${AGMSG_CODEX_PRESERVE_CURRENT_MONITOR:-}" = "1" ]; then
      return 0
    fi
    local stopped
    stopped=$(stop_codex_bridge "$project")
    if [ "${stopped:-0}" -gt 0 ]; then
      echo "Stopped $stopped Codex bridge/app monitor process(es) for this project and cleaned their run files."
    fi
  fi
}

agmsg_delivery_runtime_status() {
  local type="$1" project="$2"
  local pairs found=0
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

    local healthfile health_status health_failures health_error health_updated
    healthfile="$RUN_DIR/codex-app-monitor.$team.$name.health"
    if [ -f "$healthfile" ]; then
      health_status=$(awk -F= '/^status=/{sub(/^status=/, ""); print; exit}' "$healthfile" 2>/dev/null || true)
      health_failures=$(awk -F= '/^consecutive_failures=/{sub(/^consecutive_failures=/, ""); print; exit}' "$healthfile" 2>/dev/null || true)
      health_error=$(awk -F= '/^last_error=/{sub(/^last_error=/, ""); print; exit}' "$healthfile" 2>/dev/null || true)
      health_updated=$(awk -F= '/^updated_at=/{sub(/^updated_at=/, ""); print; exit}' "$healthfile" 2>/dev/null || true)
      echo "Codex monitor health: $team/$name status=${health_status:-unknown} failures=${health_failures:-unknown} last_error=${health_error:-unknown} updated=${health_updated:-unknown}"
    fi

    local base pidfile metafile pid meta_pid meta_project meta_type meta_ok
    base="$RUN_DIR/codex-bridge.$team.$name"
    pidfile="$base.pid"
    metafile="$base.meta"

    local app_base app_pidfile app_metafile app_pid app_thread app_transport
    app_base="$RUN_DIR/codex-app-monitor.$team.$name"
    app_pidfile="$app_base.pid"
    app_metafile="$app_base.meta"

    local chat_metafile chat_project chat_type chat_transport chat_status chat_updated
    chat_metafile="$RUN_DIR/codex-chat-visible.$team.$name.meta"

    if [ ! -f "$pidfile" ]; then
      if [ -f "$app_pidfile" ] && [ -f "$app_metafile" ]; then
        app_pid=$(cat "$app_pidfile" 2>/dev/null || true)
        app_thread=$(awk -F= '/^thread=/{sub(/^thread=/, ""); print; exit}' "$app_metafile" 2>/dev/null || true)
        app_transport=$(awk -F= '/^transport=/{sub(/^transport=/, ""); print; exit}' "$app_metafile" 2>/dev/null || true)
        if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
          echo "Codex app monitor: $team/$name alive (pid $app_pid, thread $app_thread, transport ${app_transport:-codex-app-exec-resume})"
        else
          echo "Codex app monitor: $team/$name stale pidfile (pid ${app_pid:-empty} not running)"
        fi
      elif [ -f "$chat_metafile" ]; then
        chat_project=$(awk -F= '/^project=/{sub(/^project=/, ""); print; exit}' "$chat_metafile" 2>/dev/null || true)
        chat_type=$(awk -F= '/^type=/{sub(/^type=/, ""); print; exit}' "$chat_metafile" 2>/dev/null || true)
        chat_transport=$(awk -F= '/^transport=/{sub(/^transport=/, ""); print; exit}' "$chat_metafile" 2>/dev/null || true)
        chat_status=$(awk -F= '/^status=/{sub(/^status=/, ""); print; exit}' "$chat_metafile" 2>/dev/null || true)
        chat_updated=$(awk -F= '/^updated_at=/{sub(/^updated_at=/, ""); print; exit}' "$chat_metafile" 2>/dev/null || true)
        if [ "$chat_project" = "$project" ] && [ "$chat_type" = "$type" ]; then
          echo "Codex chat-visible turn: $team/$name armed (transport ${chat_transport:-codex-chat-visible-turn}, status ${chat_status:-waiting_for_chat_turn}, updated ${chat_updated:-unknown})"
        else
          echo "Codex chat-visible turn: $team/$name stale metadata"
        fi
      else
        echo "Codex bridge: $team/$name not running"
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
    [ -n "$meta_pid" ] && [ "$meta_pid" != "$pid" ] && meta_ok=0
    [ -n "$meta_project" ] && [ "$meta_project" != "$project" ] && meta_ok=0
    [ -n "$meta_type" ] && [ "$meta_type" != "$type" ] && meta_ok=0
    if [ "$meta_ok" -ne 1 ]; then
      echo "Codex bridge: $team/$name stale pidfile (metadata mismatch)"
      continue
    fi

    if kill -0 "$pid" 2>/dev/null; then
      echo "Codex bridge: $team/$name alive (pid $pid)"
    else
      echo "Codex bridge: $team/$name stale pidfile (pid $pid not running)"
    fi
  done <<< "$pairs"

  if [ "$found" -eq 0 ]; then
    echo "Codex bridge: no identities registered for this project"
  fi
}
