#!/usr/bin/env bash
# Shared "rule-file" delivery behavior.
#
# Some agent types integrate by writing a small markdown rules file that tells
# the agent to poll the agmsg inbox after each tool call (gemini, antigravity,
# opencode). Their per-type plug (scripts/drivers/types/<name>/_delivery.sh) is then a one-line
# delegation to rulefile_apply.
#
# Runs in delivery.sh's sourced context: resolve_hooks_file and SKILL_DIR are
# provided by the caller (delivery.sh sources this lib and the type plug).
rulefile_apply() {
  local type="$1" project="$2" mode="$3"
  local rule_file
  rule_file="$(resolve_hooks_file "$type" "$project")"

  # Always start clean; each mode rewrites (or leaves absent) the rule file.
  rm -f "$rule_file"

  case "$mode" in
    turn|both)
      mkdir -p "$(dirname "$rule_file")"
      cat > "$rule_file" <<EOF
# agmsg Integration Rule

## PostToolUse
After each tool call, automatically check the agmsg inbox for unread messages.
- Command: '$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'

## Terminal/pane self-awareness
Asked about your own terminal, pane, or driver — or before using arrange/peek/poke
— run '$SKILL_DIR/scripts/where.sh' first and answer from its terminal=/capabilities=
fields. Never guess from environment variables or a grep/ps command; a driver
that IS present can be wrongly reported absent that way. Per-driver detail:
'$SKILL_DIR/scripts/drivers/terminals/<terminal>/SKILL.md' (terminal= names which).
EOF
      ;;
    monitor)
      echo "Warning: 'monitor' mode is not fully supported for $type yet. Using turn-based hook." >&2
      rulefile_apply "$type" "$project" turn
      ;;
    off)
      : # rule file already removed
      ;;
  esac
}

# Status for rule-file types: the rule file's presence is the whole state —
# present means turn-mode is active, absent means off (no monitor for these).
rulefile_status() {
  local type="$1" project="$2"
  local rule_file
  rule_file="$(resolve_hooks_file "$type" "$project")"
  if [ -f "$rule_file" ]; then echo "mode: turn"; else echo "mode: off"; fi
}
