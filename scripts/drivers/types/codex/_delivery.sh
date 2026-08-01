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
  echo "Codex monitor is enabled."
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

# Loaded-thread count for this project, resolved AT MOST ONCE per status run and
# left in _AGMSG_CODEX_LOADED_COUNT (empty = could not ask). Two reasons not to do
# this per identity: `status` should not take N network round-trips to print, and
# a stale port file whose port is held by something that accepts but never speaks
# WebSocket would stall on each one. The timeouts are deliberately far below the
# bridge's own defaults -- this is a status line, not a delivery path, and a slow
# answer here is worth less than a prompt one.
agmsg_codex_probe_loaded_count() {
  local project="$1" port_file port node_bin
  [ -n "${_AGMSG_CODEX_LOADED_PROBED:-}" ] && return 0
  _AGMSG_CODEX_LOADED_PROBED=1
  _AGMSG_CODEX_LOADED_COUNT=""
  port_file="$RUN_DIR/codex-app-server.$(printf '%s' "$project" | agmsg_sha1 2>/dev/null).port"
  port="$(cat "$port_file" 2>/dev/null || true)"
  [ -n "$port" ] || return 0
  node_bin="$(agmsg_resolve_node 2>/dev/null || true)"
  [ -n "$node_bin" ] || return 0
  { command -v "$node_bin" >/dev/null 2>&1 || [ -x "$node_bin" ]; } || return 0
  _AGMSG_CODEX_LOADED_COUNT="$("$node_bin" "$SCRIPT_DIR/drivers/types/codex/codex-bridge.js" \
    --app-server "ws://127.0.0.1:$port" --print-loaded-threads \
    --connect-timeout-ms "${AGMSG_CODEX_STATUS_PROBE_TIMEOUT_MS:-1500}" \
    --request-timeout-ms "${AGMSG_CODEX_STATUS_PROBE_TIMEOUT_MS:-1500}" 2>/dev/null | grep -c . || true)"
  return 0
}

# Why a role has no bridge. A seat (role-session record) is what every layer of
# the monitor path requires, so its absence -- not a dead process -- is the usual
# reason nothing is running. When the seat is missing, the loaded-thread count is
# what decides whether the next session can seed one, so report that too (#579).
agmsg_codex_report_missing_bridge() {
  local team="$1" name="$2" project="$3" seat
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/role-session.sh"
  seat="$(agmsg_role_session_uuid "$team" "$name" 2>/dev/null || true)"
  if [ -n "$seat" ]; then
    echo "Codex bridge: $team/$name not running (seat recorded: $seat)"
    return 0
  fi

  agmsg_codex_probe_loaded_count "$project"

  case "${_AGMSG_CODEX_LOADED_COUNT:-}" in
    "")
      echo "Codex bridge: $team/$name has no session recorded, and no app-server to ask"
      echo "  Start Codex through monitor mode in this project; the seat is recorded then."
      ;;
    0)
      echo "Codex bridge: $team/$name has no session recorded (no Codex thread is loaded yet)"
      echo "  Start Codex through monitor mode in this project; the seat is recorded then."
      ;;
    1)
      echo "Codex bridge: $team/$name has no session recorded, though one thread is loaded"
      echo "  That combination is unexpected -- the seat is normally written for it."
      ;;
    *)
      echo "Codex bridge: $team/$name has no session recorded ($_AGMSG_CODEX_LOADED_COUNT threads loaded, none identifiable as its session)"
      echo "  Recreate this project's app-server so the next session can be identified:"
      echo "    $SCRIPT_DIR/delivery.sh set off codex $project"
      echo "    $SCRIPT_DIR/delivery.sh set monitor codex $project"
      echo "  This also stops any other Codex bridge for this project."
      ;;
  esac
}

agmsg_delivery_runtime_status() {
  local type="$1" project="$2"
  local pairs found=0 any_alive=0
  _AGMSG_CODEX_LOADED_PROBED=""
  _AGMSG_CODEX_LOADED_COUNT=""
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

    local base pidfile metafile pid meta_pid meta_project meta_type meta_ok want_proj have_proj
    base="$RUN_DIR/codex-bridge.$team.$name"
    pidfile="$base.pid"
    metafile="$base.meta"

    if [ ! -f "$pidfile" ]; then
      # "not running" reads as "the bridge process died". The far more common
      # cause is that this role has no seat, which no layer of the monitor path
      # says out loud: the SessionStart hook exits 0, the launcher re-execs, and
      # the only visible symptom is this line. Say which one it is.
      agmsg_codex_report_missing_bridge "$team" "$name" "$project"
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
    # The bridge records its project via Node's path.resolve (C:\x\y on
    # Windows) while callers pass Git Bash spellings (/c/x/y or C:/x/y), so a
    # verbatim compare mislabels every live bridge stale. Compare canonical
    # normalized forms instead.
    if [ -n "$meta_project" ]; then
      want_proj="$(agmsg_normalize_project_path "$(agmsg_canonical_path "$project")")"
      have_proj="$(agmsg_normalize_project_path "$(agmsg_canonical_path "$meta_project")")"
      [ "$have_proj" != "$want_proj" ] && meta_ok=0
    fi
    [ -n "$meta_type" ] && [ "$meta_type" != "$type" ] && meta_ok=0
    if [ "$meta_ok" -ne 1 ]; then
      echo "Codex bridge: $team/$name stale pidfile (metadata mismatch)"
      continue
    fi

    if _agmsg_pid_alive "$pid"; then
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
