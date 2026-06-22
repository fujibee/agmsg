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

    local base pidfile metafile pid meta_pid meta_project meta_type meta_ok
    base="$RUN_DIR/codex-bridge.$team.$name"
    pidfile="$base.pid"
    metafile="$base.meta"

    if [ ! -f "$pidfile" ]; then
      echo "Codex bridge: $team/$name not running"
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
