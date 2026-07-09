#!/usr/bin/env bash
# opencode delivery plug — markdown rule-file. delivery_modes=monitor turn off,
# so mode=both never reaches this function (rejected by delivery.sh's central
# gate before apply runs). Uses resolve_hooks_file + SKILL_DIR from delivery.sh's
# sourced context.
#
# monitor mode: opencode-sentinel's `sentinel_monitor` tool runs a shell command
# resident and streams its stdout lines into idle sessions too — the same shape
# as Claude Code's Monitor tool. The rule instructs the agent to launch
# watch.sh under it at session start (or on /agmsg). watch.sh is runtime-agnostic
# and tolerates an empty session-id arg, so the command is safe even when
# $SENTINEL_SESSION_ID is unset in the tool's own shell. A fallback (turn-mode
# self-poll) is included for the case where `sentinel_monitor` is unavailable.
agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")

  rm -f "$rule_file"

  case "$mode" in
    turn)
      mkdir -p "$(dirname "$rule_file")"
      cat <<EOF > "$rule_file"
<!-- agmsg-delivery-mode: turn -->
# agmsg Integration Rule

## PostToolUse
After each tool call, automatically check the agmsg inbox for unread messages.
- Command: '$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'
EOF
      ;;
    monitor)
      mkdir -p "$(dirname "$rule_file")"
      cat <<EOF > "$rule_file"
<!-- agmsg-delivery-mode: monitor -->
# agmsg Integration Rule

## Real-time inbox watcher

At session start (or the first time you run /agmsg this session), launch a
resident inbox watcher with the \`sentinel_monitor\` tool so incoming agmsg
messages stream into this conversation as they arrive:

- command: '$SKILL_DIR/scripts/watch.sh' "\$SENTINEL_SESSION_ID" '$project' $type
- description: agmsg inbox stream

Do not launch it more than once per session — if a watcher is already
streaming, skip this step.

### Fallback (no sentinel_monitor tool)

If the \`sentinel_monitor\` tool is not available, fall back to a turn-based
self-check instead: after each tool call, run
'$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'
to check the agmsg inbox for unread messages.
EOF
      ;;
    off)
      : # rule file already removed
      ;;
  esac
}
agmsg_delivery_status() {
  local type="$1" project="$2"
  local rule_file
  rule_file="$(resolve_hooks_file "$type" "$project")"
  if [ ! -f "$rule_file" ]; then
    echo "mode: off"
  elif grep -q "agmsg-delivery-mode: monitor" "$rule_file" 2>/dev/null; then
    echo "mode: monitor"
  else
    echo "mode: turn"
  fi
}
