#!/usr/bin/env bash
# pi delivery plug — project-local Pi extension (.pi/extensions/agmsg.ts).
#
# Pi's session store takes a writer lease, so an external `pi --print` / watch.sh
# cannot inject into the live TUI. Delivery is in-process:
#   turn    — the extension checks inbox.sh on agent_settled
#   monitor — the same extension polls unread messages on a timer
#   off     — the extension file is removed
#
# delivery_modes=monitor turn off, so mode=both never reaches this function
# (rejected by delivery.sh's central gate). Uses resolve_hooks_file + SKILL_DIR
# from delivery.sh's sourced context.
#
# on_disable is a no-op besides apply's file removal: do NOT fall through to
# the default teardown (which stops this project's watch.sh). Another agent
# type on the same project may hold a live watcher.

_agmsg_pi_json_string() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

_agmsg_pi_write_extension() {
  local dest="$1" mode="$2"
  local src="$SKILL_DIR/scripts/drivers/types/pi/extension.ts"
  local tmp skill_json poll_ms
  [ -f "$src" ] || { echo "pi delivery: missing extension template $src" >&2; return 1; }

  mkdir -p "$(dirname "$dest")"
  skill_json="$(_agmsg_pi_json_string "$SKILL_DIR")"
  if [ "$mode" = "monitor" ]; then
    poll_ms=15000
  else
    poll_ms=0
  fi

  tmp="${dest}.tmp.$$"
  # The shipped extension.ts is a template: mode/skill-dir/poll-ms are filled
  # here so the running copy is pinned to this install and this delivery mode.
  # Bash replacement (not sed) so a skill path cannot be read as a delimiter.
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//__AGMSG_DELIVERY_MODE__/${mode}}
    line=${line//__AGMSG_SKILL_DIR_JSON__/${skill_json}}
    line=${line//__AGMSG_POLL_MS__/${poll_ms}}
    printf '%s\n' "$line"
  done < "$src" > "$tmp"
  mv "$tmp" "$dest"
}

agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local ext_file
  ext_file=$(resolve_hooks_file "$type" "$project")

  rm -f "$ext_file"

  case "$mode" in
    turn|monitor)
      _agmsg_pi_write_extension "$ext_file" "$mode"
      ;;
    off)
      : # extension already removed
      ;;
  esac
}

agmsg_delivery_status() {
  local type="$1" project="$2"
  local ext_file
  ext_file="$(resolve_hooks_file "$type" "$project")"
  if [ ! -f "$ext_file" ]; then
    echo "mode: off"
  elif grep -q "agmsg-delivery-mode: monitor" "$ext_file" 2>/dev/null; then
    echo "mode: monitor"
  else
    echo "mode: turn"
  fi
}

agmsg_delivery_on_enable() {
  local mode="$1"
  case "$mode" in
    turn|monitor)
      echo "Pi loads the project extension from .pi/extensions/agmsg.ts. Run /reload (or restart Pi) so this session picks it up."
      ;;
  esac
}

agmsg_delivery_on_disable() {
  echo "Removed the Pi agmsg extension for this project. Other agent types' watchers are left running."
}
