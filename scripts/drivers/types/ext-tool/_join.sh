#!/usr/bin/env bash
# ext-tool join plug. Sourced into join.sh's own shell by its generic
# per-type hook loader (SCRIPT_DIR, SKILL_DIR, TEAM, AGENT_ID, AGENT_TYPE are
# already in scope by the time this runs); neither function below may call
# exit -- join.sh decides what a non-zero return means.
#
# ext-tool takes `--tool <tool>` in place of a project path: it is a program,
# not a session tied to a filesystem project the way every other type is.
# Refuses outright (writes no registration; join.sh exits without ever
# reaching the write) when the tool doesn't exist or the member has no
# config yet -- an unconfigured ext-tool member would otherwise join fine
# and then fail every send in silence.

# Consumes the args after <team> <agent_id> <type> ($1=--tool, $2=<tool>,
# optional $3=--force). Sets PROJECT_PATH and FORCE, the same two globals
# every other type's own generic parsing sets. Prints its own message to
# stderr and returns 1 on any refusal; never calls exit itself.
agmsg_join_type_parse_args() {
  if [ "${1:-}" != "--tool" ] || [ -z "${2:-}" ]; then
    echo "Usage: join.sh <team> <agent_id> ext-tool --tool <tool> [--force]" >&2
    return 1
  fi
  local tool="$2"
  # $tool becomes a path segment (drivers/ext-tools/$tool/) below; validate
  # before that, not after (same allow-list send.sh's message plug and
  # ext-tool-dispatch.sh use for the same reason).
  agmsg_validate_tool_name "$tool" || return 1
  # A human-readable placeholder, not a real path: ext-tool has no project.
  # The registration still carries a `project` field (every other type's
  # does) so downstream JSON readers never have to special-case ext-tool for
  # ITS ABSENCE; they just never resolve it to anything on disk.
  PROJECT_PATH="(ext-tool:$tool)"
  FORCE=0
  if [ "${3:-}" = "--force" ]; then
    FORCE=1
  fi

  local driver_dir="$SCRIPT_DIR/drivers/ext-tools/$tool"
  if [ ! -f "$driver_dir/tool.conf" ]; then
    local available="" d
    for d in "$SCRIPT_DIR"/drivers/ext-tools/*/; do
      [ -f "${d}tool.conf" ] || continue
      available="${available:+$available, }$(basename "$d")"
    done
    echo "Unknown ext-tool: '$tool' (available: ${available:-none})" >&2
    return 1
  fi

  local member_config="$SKILL_DIR/ext-tools/$TEAM/$AGENT_ID.conf"
  if [ ! -f "$member_config" ]; then
    {
      echo "agmsg: '$tool' is not configured for '$AGENT_ID' in team '$TEAM' yet."
      echo "  Follow $driver_dir/SETUP.md to configure it, then join again."
      echo "  See how it's asked for things: bash \"$SKILL_DIR/scripts/ext-tool.sh\" usage $tool"
    } >&2
    return 1
  fi
  return 0
}

# ext-tool has no project or pane of its own -- join.sh skips
# resolve-project/normalize AND pane resolution/recording (one shared check
# governs both) when this returns success. Attempting either anyway used to
# resolve THIS SEAT's own pane instead of ext-tool's (which does not exist)
# and print a confusing "already recorded as ..." warning (review finding).
agmsg_join_type_skip_resolve() {
  return 0
}
