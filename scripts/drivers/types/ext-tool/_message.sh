#!/usr/bin/env bash
# ext-tool message plug. Sourced into send.sh's own shell by its generic
# per-type hook loader (SCRIPT_DIR is already in scope); this hook may not
# call exit -- any failure it hits must be reported back as a reply to the
# sender, never as a failure of the send itself (the message is already
# saved by the time this runs).
#
# Fires only when $to is joined as ext-tool ON THIS MACHINE (its member
# config exists locally) -- a message that only arrived here through remote
# sync is explicitly out of scope for v1 (the tool never ran anything for it
# on the machine it was actually addressed to). See
# scripts/drivers/ext-tools/README.md for the adapter contract itself.

# $1=team $2=from $3=to $4=message_id $5=body_file (send.sh's own copy;
# read-only here, not ours to delete).
agmsg_type_on_message() {
  local team="$1" from="$2" to="$3" msg_id="$4" body_file="$5"
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/validate.sh"

  local fail_reason="" tool_name="" ext_tool_config
  ext_tool_config="$SCRIPT_DIR/../ext-tools/$team/$to.conf"
  if [ ! -f "$ext_tool_config" ]; then
    fail_reason="not configured on this machine"
  else
    # Same defensive key=value read as ext-tool-dispatch.sh's own timeout=
    # read: never sourced, first match, empty on any miss.
    local line
    line="$( { grep -E '^[[:space:]]*tool[[:space:]]*=' "$ext_tool_config" 2>/dev/null || true; } | head -1)"
    tool_name="${line#*=}"
    tool_name="${tool_name#"${tool_name%%[![:space:]]*}"}"
    tool_name="${tool_name%"${tool_name##*[![:space:]]}"}"
    if [ -z "$tool_name" ]; then
      fail_reason="its config names no tool"
    elif ! agmsg_validate_tool_name "$tool_name" >/dev/null 2>&1; then
      # tool='s value flows straight into a path
      # (drivers/ext-tools/$tool_name/handle). Unlike a --tool argument at
      # join time -- which never gets this far unless the directory it names
      # already existed -- this comes from a file that could have been
      # hand-edited or corrupted, so it gets the same shared character-class
      # check as every other path built from a tool name (lib/validate.sh),
      # not just the existence check below.
      fail_reason="its config names an invalid tool '$tool_name'"
    elif [ ! -x "$SCRIPT_DIR/drivers/ext-tools/$tool_name/handle" ]; then
      fail_reason="unknown tool '$tool_name'"
    fi
  fi

  if [ -n "$fail_reason" ]; then
    storage_send "$team" "$to" "$from" "$to: processing failed ($fail_reason)" >/dev/null 2>&1 || true
    return 0
  fi

  # A separate copy for the detached dispatch below: it runs asynchronously
  # and owns (and eventually deletes) this file itself; the shared
  # $body_file belongs to send.sh's own loop, not to us.
  mkdir -p "$SCRIPT_DIR/../run"
  local dispatch_body_file
  dispatch_body_file="$(mktemp)"
  cp "$body_file" "$dispatch_body_file"
  nohup bash "$SCRIPT_DIR/internal/ext-tool-dispatch.sh" \
    "$team" "$from" "$to" "$tool_name" "$msg_id" "$dispatch_body_file" \
    >>"$SCRIPT_DIR/../run/ext-tool-dispatch.$team.$to.log" 2>&1 3>&- 4>&- &
  disown 2>/dev/null || true
}
