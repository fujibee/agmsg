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

agmsg_codex_shim_path_note() {
  # "mode: monitor" only means a project is CONFIGURED for monitor delivery;
  # it says nothing about whether `codex` on PATH actually reaches the shim
  # right now. A PATH-based install (codex-shim-install.sh install, or a raw
  # symlink) that loses to the real Codex binary in PATH order launches
  # completely unmonitored sessions with no other signal at all. See #387/#397.
  #
  # This is inherently a best-effort hint, not a diagnosis: the shim FILE
  # existing at $HOME/.agents/bin/codex does NOT mean this install relies on
  # PATH resolution for it. The shell-function method (on_enable's primary
  # recommendation) is the common case, and having the PATH shim file ALSO
  # present alongside it is normal, not contradictory -- a function takes
  # priority over PATH in an interactive shell regardless of what's on PATH,
  # and a fresh non-interactive `command -v codex` here never sees that
  # function at all, so it can look like a "mismatch" on a perfectly healthy,
  # function-routed setup. Found in real-machine testing after the first cut
  # of this check warned unconditionally on exactly that combination.
  #
  # So: only surface this note when the PATH shim file exists AND resolves
  # to something else AND no bridge for this project has ever come alive
  # (weak but non-alarmist corroboration -- a live/previously-live bridge
  # means SOMETHING is routing correctly already, by whichever method).
  # Phrased as a conditional hint, not an assertion of brokenness.
  local project="$1" any_alive="$2"
  [ "$any_alive" = "0" ] || return 0

  local marker="Optional Codex entrypoint shim for agmsg monitor mode"
  local shim_bin="$HOME/.agents/bin/codex"
  [ -f "$shim_bin" ] && grep -q "$marker" "$shim_bin" 2>/dev/null || return 0

  local resolved
  resolved="$(command -v codex 2>/dev/null || true)"
  if [ -n "$resolved" ] && [ "$resolved" != "$shim_bin" ] && ! (grep -q "$marker" "$resolved" 2>/dev/null); then
    echo "Note: an agmsg codex shim is installed at $shim_bin, but 'codex' resolves to $resolved in this non-interactive check, and no bridge for this project has come alive yet."
    echo "  If you launch Codex via the agmsg shell function (codex() in your shell profile), this is expected and fine -- a function isn't visible to this check."
    echo "  If you rely on the PATH-based shim instead, put \$HOME/.agents/bin earlier in PATH."
  fi
}

agmsg_delivery_runtime_status() {
  local type="$1" project="$2"
  local pairs found=0 any_alive=0
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
      any_alive=1
    else
      echo "Codex bridge: $team/$name stale pidfile (pid $pid not running)"
    fi
  done <<< "$pairs"

  if [ "$found" -eq 0 ]; then
    echo "Codex bridge: no identities registered for this project"
  fi

  # Capture the FULL output rather than piping into `head -1`: head closing
  # its read end after one line while agmsg_delivery_status_default is still
  # writing more would SIGPIPE it, and under this script's set -euo
  # pipefail that aborts the whole `delivery.sh status` call outright --
  # the same class of bug fixed in #423 (sort | head under pipefail), now
  # avoided here by never piping into an early-closing reader at all.
  local full_status mode_line
  full_status="$(agmsg_delivery_status_default "$type" "$project" 2>/dev/null || true)"
  mode_line="${full_status%%$'\n'*}"
  case "$mode_line" in
    "mode: monitor"|"mode: both") agmsg_codex_shim_path_note "$project" "$any_alive" ;;
  esac
}
