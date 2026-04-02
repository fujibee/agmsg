#!/usr/bin/env bash
set -euo pipefail

# Manage auto message checking hooks.
# Usage: hook.sh on  <type> <project_path>
#        hook.sh off <type> <project_path>

ACTION="${1:?Usage: hook.sh on|off ...}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_NAME="$(basename "$SKILL_DIR")"

# --- Actions ---

do_on() {
  local TYPE="${1:?Usage: hook.sh on <type> <project_path>}"
  local PROJECT="${2:?Missing project_path}"

  case "$TYPE" in
    claude-code)
      local SETTINGS_FILE="$PROJECT/.claude/settings.local.json"
      local CHECK_CMD="'$SKILL_DIR/scripts/check-inbox.sh' '$TYPE' '$PROJECT'"
      mkdir -p "$PROJECT/.claude"

      python3 - "$SETTINGS_FILE" "$CHECK_CMD" "$SKILL_NAME" <<'PYEOF'
import json, os, sys

settings_file, check_cmd, marker = sys.argv[1], sys.argv[2], sys.argv[3]

settings = json.load(open(settings_file)) if os.path.exists(settings_file) else {}

hook_entry = {
    "matcher": "",
    "hooks": [{"type": "command", "command": check_cmd}]
}

hooks = settings.setdefault("hooks", {})
stop_hooks = hooks.setdefault("Stop", [])

idx = next((i for i, h in enumerate(stop_hooks)
            if any(marker in hh.get("command", "") for hh in h.get("hooks", []))), None)

if idx is not None:
    stop_hooks[idx] = hook_entry
else:
    stop_hooks.append(hook_entry)

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
      echo "Hook enabled for $PROJECT (claude-code)"
      ;;
    codex)
      echo "Codex hook support not yet implemented"
      exit 1
      ;;
    *)
      echo "Unknown type: $TYPE" >&2
      exit 1
      ;;
  esac
}

do_off() {
  local TYPE="${1:?Usage: hook.sh off <type> <project_path>}"
  local PROJECT="${2:?Missing project_path}"

  case "$TYPE" in
    claude-code)
      local SETTINGS_FILE="$PROJECT/.claude/settings.local.json"

      if [ ! -f "$SETTINGS_FILE" ]; then
        echo "No hook configured"
        exit 0
      fi

      python3 - "$SETTINGS_FILE" "$SKILL_NAME" "$PROJECT" <<'PYEOF'
import json, sys

settings_file, marker, project = sys.argv[1], sys.argv[2], sys.argv[3]

settings = json.load(open(settings_file))
hooks = settings.get("hooks", {})
stop_hooks = hooks.get("Stop", [])

filtered = [h for h in stop_hooks
            if not any(marker in hh.get("command", "") for hh in h.get("hooks", []))]

if len(filtered) == len(stop_hooks):
    print("No hook configured")
else:
    if filtered:
        hooks["Stop"] = filtered
    else:
        hooks.pop("Stop", None)
    if not hooks:
        settings.pop("hooks", None)

    with open(settings_file, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(f"Hook disabled for {project} (claude-code)")
PYEOF
      ;;
    codex)
      echo "Codex hook support not yet implemented"
      exit 1
      ;;
    *)
      echo "Unknown type: $TYPE" >&2
      exit 1
      ;;
  esac
}

# --- Dispatch ---

case "$ACTION" in
  on)  do_on "$@" ;;
  off) do_off "$@" ;;
  *)   echo "Unknown action: $ACTION (use on|off)" >&2; exit 1 ;;
esac
