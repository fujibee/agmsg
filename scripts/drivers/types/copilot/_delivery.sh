#!/usr/bin/env bash
# copilot delivery plug — JSON hooks file (.github/hooks/agmsg.json). Only turn|off
# reach this function: copilot's manifest declares delivery_modes=turn off, so
# delivery.sh's central gate rejects monitor/both before apply runs (and before
# any file is touched, so a fat-fingered 'monitor' can't wipe a working turn
# hook). Uses resolve_hooks_file + SKILL_DIR from delivery.sh's sourced context.
agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")

  # Strip first so re-applying turn is an idempotent rewrite and turn->off
  # cleanly removes the file.
  rm -f "$hooks_file"

  if [ "$mode" = "turn" ]; then
    mkdir -p "$(dirname "$hooks_file")"
    local cmd="'$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'"
    # json_quote handles JSON-string escaping for arbitrary command strings
    # (project paths may contain JSON-special chars).
    local cmd_json
    cmd_json=$(agmsg_sqlite_mem "SELECT json_quote('$(printf '%s' "$cmd" | LC_ALL=C sed "s/'/''/g")');")
    # Use PascalCase 'Stop' trigger so the input payload field names match
    # the snake_case form (session_id) that check-inbox.sh already parses.
    cat <<EOF > "$hooks_file"
{
  "version": 1,
  "hooks": {
    "Stop": [
      {
        "type": "command",
        "bash": $cmd_json,
        "timeoutSec": 30
      }
    ]
  }
}
EOF
  fi
}
agmsg_delivery_status() { rulefile_status "$@"; }
