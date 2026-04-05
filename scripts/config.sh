#!/usr/bin/env bash
set -euo pipefail

# Manage agmsg configuration.
# Usage: config.sh get <key> [default]
#        config.sh set <key> <value>
#        config.sh show

ACTION="${1:?Usage: config.sh get|set|show ...}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../db/config.yaml"

# --- Helpers ---

# Read a dotted key from YAML (simple flat key: value format)
# Supports dotted keys like "hook.check_interval" → looks for "check_interval" under "hook:"
yaml_get() {
  local key="$1"
  local default="${2:-}"

  if [ ! -f "$CONFIG_FILE" ]; then
    echo "$default"
    return
  fi

  local section="" field=""
  if [[ "$key" == *.* ]]; then
    section="${key%%.*}"
    field="${key#*.}"
  else
    field="$key"
  fi

  local value=""
  if [ -n "$section" ]; then
    # Find value under section
    value=$(awk -v section="$section" -v field="$field" '
      /^[^ #]/ { in_section = ($0 ~ "^" section ":") }
      in_section && $0 ~ "^  " field ":" {
        sub(/^  [^ ]+:[ \t]*/, "")
        # Strip inline comments
        sub(/[ \t]+#.*$/, "")
        print
        exit
      }
    ' "$CONFIG_FILE")
  else
    # Top-level key
    value=$(awk -v field="$field" '
      /^[^ #]/ && $0 ~ "^" field ":" {
        sub(/^[^ ]+:[ \t]*/, "")
        sub(/[ \t]+#.*$/, "")
        print
        exit
      }
    ' "$CONFIG_FILE")
  fi

  if [ -n "$value" ]; then
    echo "$value"
  else
    echo "$default"
  fi
}

# Set a dotted key in YAML
yaml_set() {
  local key="$1"
  local value="$2"

  local section="" field=""
  if [[ "$key" == *.* ]]; then
    section="${key%%.*}"
    field="${key#*.}"
  else
    field="$key"
  fi

  # Create config file with defaults if it doesn't exist
  if [ ! -f "$CONFIG_FILE" ]; then
    create_default_config
  fi

  if [ -n "$section" ]; then
    # Check if section exists
    if ! grep -q "^${section}:" "$CONFIG_FILE" 2>/dev/null; then
      printf '\n%s:\n  %s: %s\n' "$section" "$field" "$value" >> "$CONFIG_FILE"
    elif grep -q "^  ${field}:" "$CONFIG_FILE" 2>/dev/null; then
      # Update existing field under section
      awk -v section="$section" -v field="$field" -v value="$value" '
        /^[^ #]/ { in_section = ($0 ~ "^" section ":") }
        in_section && $0 ~ "^  " field ":" {
          print "  " field ": " value
          next
        }
        { print }
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
      # Add field to existing section
      awk -v section="$section" -v field="$field" -v value="$value" '
        { print }
        /^[^ #]/ && $0 ~ "^" section ":" {
          print "  " field ": " value
        }
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
  else
    if grep -q "^${field}:" "$CONFIG_FILE" 2>/dev/null; then
      # Update existing top-level key
      awk -v field="$field" -v value="$value" '
        $0 ~ "^" field ":" {
          print field ": " value
          next
        }
        { print }
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
      printf '%s: %s\n' "$field" "$value" >> "$CONFIG_FILE"
    fi
  fi
}

create_default_config() {
  cat > "$CONFIG_FILE" <<'YAML'
# agmsg configuration
hook:
  check_interval: 60
YAML
}

# --- Actions ---

case "$ACTION" in
  get)
    KEY="${1:?Usage: config.sh get <key> [default]}"
    DEFAULT="${2:-}"
    yaml_get "$KEY" "$DEFAULT"
    ;;
  set)
    KEY="${1:?Usage: config.sh set <key> <value>}"
    VALUE="${2:?Usage: config.sh set <key> <value>}"
    yaml_set "$KEY" "$VALUE"
    echo "Set $KEY = $VALUE"
    ;;
  show)
    if [ -f "$CONFIG_FILE" ]; then
      cat "$CONFIG_FILE"
    else
      echo "No config file. Using defaults."
      echo ""
      create_default_config
      cat "$CONFIG_FILE"
    fi
    ;;
  *)
    echo "Unknown action: $ACTION (use get|set|show)" >&2
    exit 1
    ;;
esac
