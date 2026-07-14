#!/usr/bin/env bash

# Codex delivery plug. Monitor means one authenticated Desktop relay plus one
# exact-thread, project-owned bridge. Foreground Stop delivery remains the safe
# fallback and does not mark Codex mail read.

agmsg_delivery_apply() {
  local type="$1" project="$2" mode="$3"
  if [ "$mode" = "monitor" ]; then
    agmsg_delivery_apply_default "$type" "$project" both
  else
    agmsg_delivery_apply_default "$type" "$project" "$mode"
  fi
}

agmsg_delivery_status() {
  agmsg_delivery_status_default "$@" | sed '1s/^mode: both$/mode: monitor/'
}

agmsg_delivery_on_enable() {
  local project="$3" legacy_cleanup
  legacy_cleanup=$("$SKILL_DIR/scripts/drivers/types/codex/codex-monitor-lease.sh" \
    disarm-project "$project" 2>/dev/null || true)
  if printf '%s\n' "$legacy_cleanup" | grep -q 'lease_id='; then
    echo "Disabled legacy Codex heartbeat/watchdog lease state for this project."
  fi
  echo "Codex visible monitor beta is enabled."
  echo "Unread mail is delivered only through the authenticated Desktop relay into the exact visible task."
  echo "If the relay, Desktop, exact thread, or role bridge is unavailable, delivery downgrades to turn and mail remains unread."
  case "$SKILL_DIR" in
    "$HOME"/.agents/skills/*)
      if [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
        local relay_status
        relay_status="$("$SKILL_DIR/scripts/drivers/types/codex/codex-desktop-relayctl.sh" enable 2>&1 || true)"
        if printf '%s\n' "$relay_status" | grep -q '^status='; then
          echo "Codex Desktop relay: $relay_status"
          echo "Restart Codex Desktop once if it is not yet connected through the relay."
        else
          echo "WARNING: Codex Desktop relay did not start: $relay_status"
        fi
      fi
      ;;
  esac
  local codex_node
  codex_node="$(agmsg_resolve_node)"
  if ! command -v "$codex_node" >/dev/null 2>&1 && [ ! -x "$codex_node" ]; then
    echo "WARNING: Node.js ('$codex_node') was not found; monitor delivery will NOT start."
  fi
  echo "Run agmsg actas <role> in the intended visible Codex task to bind its exact thread."
  echo "For more info: $CODEX_MONITOR_DOC_URL"
}

agmsg_delivery_on_disable() {
  local project="$2" stopped lease_cleanup
  stopped="$(stop_codex_bridge "$project")"
  if [ "${stopped:-0}" -gt 0 ]; then
    echo "Stopped $stopped project-owned Codex bridge process(es) and cleaned their private run files."
  fi
  lease_cleanup=$("$SKILL_DIR/scripts/drivers/types/codex/codex-monitor-lease.sh" \
    disarm-project "$project" 2>/dev/null || true)
  [ -n "$lease_cleanup" ] && printf '%s\n' "$lease_cleanup"
  echo "The shared Codex Desktop relay remains installed for other projects and future monitor sessions."
}

agmsg_delivery_stop_directive() {
  local project="${PROJECT:-}" mode="${MODE:-}"
  if [ "$mode" = "turn" ] && [ -n "$project" ]; then
    [ "${AGMSG_CODEX_PRESERVE_CURRENT_MONITOR:-}" = "1" ] && return 0
    local stopped
    stopped="$(stop_codex_bridge "$project")"
    if [ "${stopped:-0}" -gt 0 ]; then
      echo "Stopped $stopped project-owned Codex bridge process(es) and cleaned their run files."
    fi
    "$SKILL_DIR/scripts/drivers/types/codex/codex-monitor-lease.sh" \
      disarm-project "$project" 2>/dev/null || true
  fi
}

agmsg_delivery_runtime_status() {
  local type="$1" project="$2" relay_status meta meta_project status thread team name pid found=0 chat
  relay_status="$("$SKILL_DIR/scripts/drivers/types/codex/codex-desktop-relayctl.sh" status 2>/dev/null || true)"
  echo "Codex Desktop relay: ${relay_status:-status=unknown app_server=ws://127.0.0.1/<capability>}"

  for meta in "$RUN_DIR"/codex-bridge.*.meta; do
    [ -f "$meta" ] || continue
    meta_project="$(sed -n 's/^project=//p' "$meta" | head -1)"
    [ "$(agmsg_canonical_path "$meta_project")" = "$(agmsg_canonical_path "$project")" ] || continue
    [ "$(sed -n 's/^type=//p' "$meta" | head -1)" = "$type" ] || continue
    found=1
    team="$(sed -n 's/^team=//p' "$meta" | head -1)"
    name="$(sed -n 's/^name=//p' "$meta" | head -1)"
    thread="$(sed -n 's/^thread=//p' "$meta" | head -1)"
    pid="$(sed -n 's/^pid=//p' "$meta" | head -1)"
    status="$(sed -n 's/^status=//p' "${meta%.meta}.health" 2>/dev/null | head -1 || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "Codex visible bridge: $team/$name active pid=$pid thread=$thread health=${status:-unknown} app_server=ws://127.0.0.1/<capability>"
    else
      echo "Codex visible bridge: $team/$name stale thread=$thread health=${status:-unknown}"
    fi
  done

  for chat in "$RUN_DIR"/codex-chat-visible.*.meta; do
    [ -f "$chat" ] || continue
    meta_project="$(sed -n 's/^project=//p' "$chat" | head -1)"
    [ "$(agmsg_canonical_path "$meta_project")" = "$(agmsg_canonical_path "$project")" ] || continue
    [ "$(sed -n 's/^type=//p' "$chat" | head -1)" = "$type" ] || continue
    found=1
    team="$(sed -n 's/^team=//p' "$chat" | head -1)"
    name="$(sed -n 's/^name=//p' "$chat" | head -1)"
    thread="$(sed -n 's/^thread=//p' "$chat" | head -1)"
    echo "Codex visible turn fallback: $team/$name waiting thread=$thread unread_preserved=true"
  done
  [ "$found" -eq 1 ] || echo "Codex visible bridge: no role is currently bound for this project"
}
