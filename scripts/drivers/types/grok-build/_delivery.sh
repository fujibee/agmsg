#!/usr/bin/env bash
# grok-build delivery plug — markdown rule file (.grok/rules/agmsg.md).
#
# Why a rule file (not a hook): Grok Build's passive hooks (SessionStart/Stop)
# discard their stdout — they cannot inject anything into the conversation. A
# Stop hook running check-inbox.sh would therefore deliver NOTHING while still
# marking messages read = silent loss. So grok integrates the same way as
# gemini / antigravity / opencode: a markdown rule under <project>/.grok/rules/,
# which Grok always scans into context each turn. The rule tells the agent to
# poll its own inbox; the agent runs the check as a tool call and reads the
# output — the one delivery path Grok actually supports.
#
# The rule points at inbox.sh (not check-inbox.sh): inbox.sh prints the unread
# messages in plain text AND marks them read in the same call, so the agent sees
# exactly what gets consumed (loss-safe). check-inbox.sh wraps its output in
# Claude hook-control JSON and carries hook-only cooldown/watcher logic that is
# wrong for an agent reading tool output.
#
# Rule files need no folder-trust (Grok's trust gate is for execution —
# hooks/MCP/LSP — not rules), and a project-level .grok/rules is read even
# outside a git repo, so this also works for spawned sessions. delivery_modes is
# "turn off": turn => rule present (self-poll active), off => rule removed.
# Uses resolve_hooks_file + SKILL_DIR from delivery.sh's sourced context.
agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")

  # Always start clean; turn rewrites the rule, off leaves it absent.
  rm -f "$rule_file"

  if [ "$mode" = "turn" ]; then
    mkdir -p "$(dirname "$rule_file")"
    cat <<EOF > "$rule_file"
# agmsg — check your inbox each turn

You belong to one or more agmsg teams. Before you respond to the user on each
turn, check your agmsg inbox so you never miss a teammate's message.

1. Identify yourself (once per session is enough):
   \`$SKILL_DIR/scripts/whoami.sh '$project' $type\`
   It prints your \`agent=\` name and \`teams=\` list.
2. For each team, show and consume unread messages:
   \`$SKILL_DIR/scripts/inbox.sh <team> <your-agent-name>\`
   This prints unread messages AND marks them read in the same call, so nothing
   is lost.
3. If any messages were shown, relay them to the user before continuing with
   their request.

There is no background watcher for Grok Build — this self-check is how delivery
works. Removing this file turns automatic delivery off.
EOF
  fi
}

# Status is the rule file's presence: present => turn, absent => off (no monitor
# for a self-poll type). Same shared helper the other rule-file types use.
agmsg_delivery_status() { rulefile_status "$@"; }
