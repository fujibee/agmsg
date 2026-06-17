#!/usr/bin/env bash
# Shared driver for the "rule-file" class of agent runtimes.
#
# These runtimes read a single Markdown instruction/rule file whose *presence*
# means turn-mode delivery and whose absence means off. There is no Monitor
# equivalent, so monitor/both degrade to turn. The only per-runtime difference
# is *where* that file lives, which `resolve_hooks_file <type>` already knows —
# so a per-type driver in this class is a 3-line file that sources this lib
# (see drivers/gemini.sh). Adding a new rule-file runtime (opencode, cursor, …)
# becomes one such file plus its path entry in resolve_hooks_file.
#
# Sourced by delivery.sh, so it relies on delivery.sh's globals/functions:
#   resolve_hooks_file(), SKILL_DIR
#
# Verbs (the driver contract delivery.sh dispatches to):
#   rulefile_apply  <type> <project> <mode>   — write/remove the rule file
#   rulefile_status <type> <project>          — echo the current mode (turn|off)

rulefile_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")

  # Remove existing rule file first so re-applying turn is an idempotent
  # rewrite and turn->off cleanly removes it.
  rm -f "$rule_file"

  case "$mode" in
    turn|both)
      mkdir -p "$(dirname "$rule_file")"
      cat <<EOF > "$rule_file"
# agmsg Integration Rule

## PostToolUse
After each tool call, automatically check the agmsg inbox for unread messages.
- Command: '$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'
EOF
      ;;
    monitor)
      echo "Warning: 'monitor' mode is not fully supported for $type yet. Using turn-based hook." >&2
      rulefile_apply "$type" "$project" "turn"
      ;;
    off)
      ;;
  esac
}

# Mode is inferred from the rule file's presence: present → turn, absent → off.
rulefile_status() {
  local type="$1"
  local project="$2"
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")
  if [ -f "$rule_file" ]; then
    echo "turn"
  else
    echo "off"
  fi
}
