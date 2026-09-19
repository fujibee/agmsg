#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ext-tool.sh setup <team> <name> <tool> status
#   ext-tool.sh setup <team> <name> <tool> check <item>
#   ext-tool.sh setup <team> <name> <tool> save
#   ext-tool.sh setup <team> <name> <tool> test
#   ext-tool.sh secret <team> <name>
#
# Common entry point for configuring an ext-tool member
# (scripts/drivers/ext-tools/README.md has the full contract). `setup`
# forwards status/check/save/test to the named tool's own non-interactive
# `setup` executable, resolving <team>/<name>'s config path first — the
# conversation with the user happens at the calling seat, which reads the
# tool's SETUP.md and calls these one at a time; nothing here holds a
# conversation of its own. `secret` reads one value from the terminal without
# echoing it, writes it to a 0600 file, and reports only that it was saved —
# never the value, and never through any channel other than the terminal it
# was typed into (refused when not run on one, same as `key.sh show
# --reveal-secret`).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"

_ext_tool_available() {
  local dir name found=""
  for dir in "$SCRIPT_DIR"/drivers/ext-tools/*/; do
    [ -f "${dir}tool.conf" ] || continue
    name="$(basename "$dir")"
    found="${found:+$found, }$name"
  done
  printf '%s' "${found:-none}"
}

# Echoes the tool's driver directory, or refuses and exits.
_ext_tool_dir() {
  local tool="$1" dir
  agmsg_validate_tool_name "$tool" || exit 1
  dir="$SCRIPT_DIR/drivers/ext-tools/$tool"
  if [ ! -f "$dir/tool.conf" ]; then
    echo "Unknown ext-tool: '$tool' (available: $(_ext_tool_available))" >&2
    exit 1
  fi
  printf '%s' "$dir"
}

# Echoes the member's config path. Does not require the path to exist —
# `save` is exactly the step that creates it, and `secret` may run before a
# member is ever joined.
_ext_tool_config_path() {
  local team="$1" name="$2"
  printf '%s' "$SKILL_DIR/ext-tools/$team/$name.conf"
}

# _ext_tool_write_atomic <dest_path> <content> — same shape as key.sh's
# _key_write_identity_atomic: 0600 a same-directory temp file before any
# content touches disk, write, fsync best-effort, atomically rename over the
# destination. Never truncates an existing file in place, and mktemp's O_EXCL
# means it never follows a symlink at <dest_path>.
_ext_tool_write_atomic() {
  local dest="$1" content="$2" dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$(mktemp "$dir/.secret-XXXXXX")"
  chmod 600 "$tmp"
  trap 'rm -f "$tmp"' EXIT INT TERM
  printf '%s' "$content" > "$tmp"
  sync 2>/dev/null || true
  mv "$tmp" "$dest"
  trap - EXIT INT TERM
}

cmd_setup() {
  local team="${1:?Usage: ext-tool.sh setup <team> <name> <tool> status|check|save|test [args...]}"
  local name="${2:?Missing name}"
  local tool="${3:?Missing tool}"
  local sub="${4:?Missing subcommand (status|check|save|test)}"
  shift 4
  agmsg_validate_team_name "$team" || exit 1
  agmsg_validate_agent_name "$name" || exit 1

  local dir config_path
  dir="$(_ext_tool_dir "$tool")"
  config_path="$(_ext_tool_config_path "$team" "$name")"
  mkdir -p "$(dirname "$config_path")"

  case "$sub" in
    save)
      [ "$#" -eq 0 ] || { echo "Usage: ext-tool.sh setup <team> <name> <tool> save" >&2; exit 1; }
      "$dir/setup" save "$config_path"
      local rc=$?
      # send.sh's dispatch reads config_path's own `tool=` key to know which
      # handle to run; a tool's own `setup save` naming itself is the
      # documented contract (drivers/ext-tools/README.md), but a config with
      # a saved value and no `tool=` line would otherwise join fine and then
      # silently never dispatch anything. Make it true, not just documented.
      if [ "$rc" -eq 0 ] && [ -f "$config_path" ] && ! grep -qE '^[[:space:]]*tool[[:space:]]*=' "$config_path"; then
        printf 'tool=%s\n' "$tool" >> "$config_path"
      fi
      exit "$rc"
      ;;
    status|test)
      [ "$#" -eq 0 ] || { echo "Usage: ext-tool.sh setup <team> <name> <tool> $sub" >&2; exit 1; }
      exec "$dir/setup" "$sub" "$config_path"
      ;;
    check)
      local item="${1:?Usage: ext-tool.sh setup <team> <name> <tool> check <item>}"
      exec "$dir/setup" check "$item" "$config_path"
      ;;
    *)
      echo "Usage: ext-tool.sh setup <team> <name> <tool> status|check|save|test [args...]" >&2
      exit 1
      ;;
  esac
}

cmd_secret() {
  local team="${1:?Usage: ext-tool.sh secret <team> <name>}"
  local name="${2:?Missing name}"
  agmsg_validate_team_name "$team" || exit 1
  agmsg_validate_agent_name "$name" || exit 1

  # A secret typed here never reaches an agent: read/written directly from
  # THIS terminal only, the same guard and wording key.sh show --reveal-secret
  # already uses for the same reason.
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "agmsg: ext-tool secret requires an interactive terminal and is refused in agent mode." >&2
    exit 1
  fi

  local value dest
  read -rsp "Secret value for '$name' in team '$team': " value
  echo >&2
  [ -n "$value" ] || { echo "agmsg: empty value; nothing saved." >&2; exit 1; }
  dest="$SKILL_DIR/ext-tools/$team/$name.secret"
  _ext_tool_write_atomic "$dest" "$value"
  unset value
  echo "Saved. (The value itself is not shown or logged.)"
}

case "${1:-}" in
  setup) shift; cmd_setup "$@" ;;
  secret) shift; cmd_secret "$@" ;;
  *)
    echo "Usage: ext-tool.sh <setup <team> <name> <tool> status|check|save|test|secret <team> <name>>" >&2
    exit 1
    ;;
esac
