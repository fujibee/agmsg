#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ext-tool.sh setup <team> <name> <tool> status
#   ext-tool.sh setup <team> <name> <tool> check <item> [args...]
#   ext-tool.sh setup <team> <name> <tool> save [args...]
#   ext-tool.sh setup <team> <name> <tool> test
#   ext-tool.sh secret <team> <name>
#   ext-tool.sh secret <team> <name> --from-clipboard
#
# Common entry point for configuring an ext-tool member
# (scripts/drivers/ext-tools/README.md has the full contract). `setup`
# forwards status/check/save/test to the named tool's own non-interactive
# `setup` executable, resolving <team>/<name>'s config path first. `save`
# gets config_path plus whatever [args...] the caller gave, forwarded
# verbatim, in order -- a tool's own save may need more than config_path
# (e.g. a key file path, a channel id) and this entry point does not know or
# care what those are. `check <item>` gets [args...] the same way but WITHOUT
# config_path -- it verifies a raw, not-yet-saved value, so a tool's own
# check never expects one. The conversation with the user happens at the
# calling seat, which reads the tool's SETUP.md and calls these one at a
# time; nothing here holds a conversation of its own. `secret` reads one
# value without echoing it,
# writes it to a 0600 file, and reports only that it was saved — never the
# value. Its plain form reads from THIS terminal only (refused when not run
# on one, same as `key.sh show --reveal-secret`); `--from-clipboard` reads
# the system clipboard instead, so a user calling through an agent's `!`
# (which has no real TTY of its own) can still do this without opening a
# separate terminal -- `! bash .../ext-tool.sh secret <team> <name>
# --from-clipboard` after copying the value. The clipboard is left alone
# after reading (it is the user's, not this script's, to clear).

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
      # Whatever extra arguments the caller gave (e.g. a key file path, a
      # channel id) are forwarded verbatim after config_path -- this entry
      # point does not know or care what a given tool's own setup needs
      # beyond config_path itself (dogfood finding: this used to drop them
      # entirely, so a tool whose save needs more than config_path had no
      # way to receive it through here at all).
      "$dir/setup" save "$config_path" "$@"
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
      # config_path is NOT forwarded here (unlike save/status/test): `check`
      # exists to verify a raw, not-yet-saved value (a key file, a channel
      # id) before anything is written, so it takes exactly what the caller
      # passes after <item> -- same dogfood finding as save, just the
      # opposite direction (this used to inject config_path where a tool's
      # own check never asked for it).
      local item="${1:?Usage: ext-tool.sh setup <team> <name> <tool> check <item> [args...]}"
      shift
      exec "$dir/setup" check "$item" "$@"
      ;;
    *)
      echo "Usage: ext-tool.sh setup <team> <name> <tool> status|check|save|test [args...]" >&2
      exit 1
      ;;
  esac
}

# Runs ONE named clipboard-reader candidate's actual invocation (the flags
# each one needs differ, so this exists rather than inlining them in the
# loop below).
_ext_tool_clipboard_try() {
  case "$1" in
    pbpaste) pbpaste ;;
    wl-paste) wl-paste ;;
    xclip) xclip -selection clipboard -o ;;
    xsel) xsel --clipboard --output ;;
    powershell.exe) powershell.exe -NoProfile -Command Get-Clipboard ;;
    powershell) powershell -NoProfile -Command Get-Clipboard ;;
  esac
}

# Echoes the system clipboard's text (stdout only) on success (return 0).
# Tries every candidate found on PATH, in order, moving on to the next if
# one FAILS -- not just picking the first one found and stopping there
# regardless of whether it actually works (review finding: PATH having a
# `pbpaste` that fails for some reason used to abort immediately and
# misreport "no reader found", never trying wl-paste/xclip/etc. after it).
# Each candidate's own stderr is discarded, never surfaced to the caller: a
# clipboard reader is an external-boundary command, and its failure output
# is not guaranteed free of fragments of whatever is (or was) selected.
#
# Distinguishes "a reader was found but every one of them failed" (return 3)
# from "nothing on PATH at all" (return 4) via the RETURN CODE, not a side
# -effect variable: this function is always called as `value="$(...)"`, and
# a command substitution runs in a SUBSHELL, so a plain variable assignment
# made inside it (an earlier version set _EXT_TOOL_CLIPBOARD_TRIED=1 this
# way) is invisible to the caller once the subshell exits -- the caller's
# own copy never changes, which silently broke the whole distinction (review
# finding: every one of these two cases was reported as "no reader found").
_ext_tool_read_clipboard() {
  local bin out tried=0
  for bin in pbpaste wl-paste xclip xsel powershell.exe powershell; do
    command -v "$bin" >/dev/null 2>&1 || continue
    tried=1
    if out="$(_ext_tool_clipboard_try "$bin" 2>/dev/null)"; then
      printf '%s' "$out"
      return 0
    fi
  done
  [ "$tried" -eq 1 ] && return 3
  return 4
}

cmd_secret() {
  local team="${1:?Usage: ext-tool.sh secret <team> <name> [--from-clipboard]}"
  local name="${2:?Missing name}"
  local from_clipboard=0
  case "${3:-}" in
    --from-clipboard) from_clipboard=1 ;;
    "") ;;
    *) echo "Usage: ext-tool.sh secret <team> <name> [--from-clipboard]" >&2; exit 1 ;;
  esac
  agmsg_validate_team_name "$team" || exit 1
  agmsg_validate_agent_name "$name" || exit 1

  local value dest clipboard_rc
  if [ "$from_clipboard" -eq 1 ]; then
    # The `if` here is load-bearing, not style: this script runs under
    # `set -e`, and `value="$(_ext_tool_read_clipboard)"` as a bare statement
    # (outside any condition) would trip errexit the instant that function
    # returns non-zero, exiting the whole script right there -- before
    # `clipboard_rc=$?` or the case below ever ran (review finding: this
    # actually happened, so the two distinct failure messages were
    # unreachable dead code; the script just exited with whatever raw exit
    # code the function returned).
    if value="$(_ext_tool_read_clipboard)"; then
      clipboard_rc=0
    else
      clipboard_rc=$?
    fi
    case "$clipboard_rc" in
      0) ;;
      3) echo "agmsg: found a clipboard reader on PATH but it failed to read the clipboard." >&2; exit 1 ;;
      *) echo "agmsg: no clipboard reader found on this platform (tried pbpaste, wl-paste, xclip, xsel, powershell Get-Clipboard)." >&2; exit 1 ;;
    esac
    [ -n "$value" ] || { echo "agmsg: clipboard is empty; nothing saved." >&2; exit 1; }
  else
    # A secret typed here never reaches an agent: read/written directly from
    # THIS terminal only, the same guard and wording key.sh show
    # --reveal-secret already uses for the same reason. --from-clipboard,
    # above, is the alternative for a caller with no real TTY (an agent's
    # `!`), so this guard does not need to bend to accommodate that case.
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      echo "agmsg: ext-tool secret requires an interactive terminal (or --from-clipboard) and is refused in agent mode." >&2
      exit 1
    fi
    read -rsp "Secret value for '$name' in team '$team': " value
    echo >&2
    [ -n "$value" ] || { echo "agmsg: empty value; nothing saved." >&2; exit 1; }
  fi
  dest="$SKILL_DIR/ext-tools/$team/$name.secret"
  _ext_tool_write_atomic "$dest" "$value"
  unset value
  # The path is not a secret; the LLM at the calling seat needs it verbatim
  # as the key_file argument to the next setup check/save step, and SETUP.md
  # tells it not to construct that path itself (dogfood finding: the plain
  # "Saved." left it with no way to know the path at all).
  echo "Saved to $dest. (The value itself is not shown or logged.)"
}

case "${1:-}" in
  setup) shift; cmd_setup "$@" ;;
  secret) shift; cmd_secret "$@" ;;
  *)
    echo "Usage: ext-tool.sh <setup <team> <name> <tool> status|check|save|test|secret <team> <name>>" >&2
    exit 1
    ;;
esac
