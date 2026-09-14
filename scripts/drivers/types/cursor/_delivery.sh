#!/usr/bin/env bash
# cursor delivery plug — Cursor CLI (cursor-agent) rule file (#131).
#
# The Cursor CLI auto-loads project rules from .cursor/rules/*.mdc. An .mdc with
# `alwaysApply: true` in its frontmatter is applied on every turn, which is the
# always-on instruction channel agmsg needs — the cursor-agent equivalent of
# gemini/opencode's markdown rules file. Only turn|off reach this function:
# cursor's manifest declares delivery_modes=turn off, so delivery.sh's central
# gate rejects monitor/both first. Uses resolve_hooks_file + SKILL_DIR from
# delivery.sh's sourced context.
agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  # Refuse before any write: an empty SKILL_DIR would render broken guidance
  # paths into the rule file, and the rm -f below removes the existing rule
  # file first -- an unreadable value must never be treated as "nothing to
  # preserve" (#1234 review).
  [ -n "${SKILL_DIR:-}" ] || { echo "agmsg_delivery_apply (cursor): SKILL_DIR is not set; refusing rather than writing a broken rule file" >&2; return 1; }
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")

  rm -f "$rule_file"

  if [ "$mode" = "turn" ]; then
    mkdir -p "$(dirname "$rule_file")"
    cat <<EOF > "$rule_file"
---
alwaysApply: true
---
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

## Teammates: placement, status, and reaching them
A teammate's placement and status: '$SKILL_DIR/scripts/team.sh' <team> — never a
stale memory of their last known pane. Act on one with '$SKILL_DIR/scripts/peek.sh'
/ 'poke.sh' / 'arrange.sh' <team> <name> directly, not a guess: its exit code
says whether it worked and, if not, why.
EOF
  fi
}
agmsg_delivery_status() { rulefile_status "$@"; }
