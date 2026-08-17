#!/usr/bin/env bash
# cursor delivery plug — Cursor CLI (cursor-agent) rule file (#131).
#
# The Cursor CLI auto-loads project rules from .cursor/rules/*.mdc. An .mdc with
# `alwaysApply: true` in its frontmatter is applied on every turn, which is the
# always-on instruction channel agmsg needs — the cursor-agent equivalent of
# gemini/opencode's markdown rules file. delivery_modes is "turn monitor off"
# (both is rejected by delivery.sh before apply). monitor writes the same file
# telling the agent to launch watch.sh via Shell notify_on_output. Uses
# resolve_hooks_file + SKILL_DIR from delivery.sh's sourced context.
agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
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
EOF
  elif [ "$mode" = "monitor" ]; then
    mkdir -p "$(dirname "$rule_file")"
    # The watch.sh command below passes "${CURSOR_CONVERSATION_ID:--}"
    # (sentinel `-`), NOT "$CURSOR_CONVERSATION_ID": a host that re-evaluates
    # the command with the var unset would drop a quoted-empty first arg and
    # shift project/type. `-` survives as a real argument and watch.sh folds
    # it into the empty-session-id path.
    cat <<EOF > "$rule_file"
---
alwaysApply: true
---
<!-- agmsg-delivery-mode: monitor -->
# agmsg Integration Rule

## Real-time inbox watcher

At session start (or the first time you run /agmsg this session), launch a
resident inbox watcher with Shell + \`notify_on_output\` so incoming agmsg
messages wake this idle CLI session:

- command: '$SKILL_DIR/scripts/watch.sh' "\${CURSOR_CONVERSATION_ID:--}" '$project' $type
- title: agmsg inbox stream
- notify_on_output.pattern: ^[0-9]{4}-[0-9]{2}-[0-9]{2}T|^ERROR:

Do not launch it more than once per session — if a watcher is already
streaming, skip this step. Do not use a plain background shell or \`/loop\`.
EOF
  fi
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

agmsg_delivery_on_enable() {
  local mode="$1" type="$2" project="$3"
  [ "$mode" = "monitor" ] || return 0
  cat <<EOF

AGMSG-DIRECTIVE: start one background Shell now:
  command: $SKILL_DIR/scripts/watch.sh "\${CURSOR_CONVERSATION_ID:--}" '$project' $type
  title: agmsg inbox stream
  block_until_ms: 0
  notify_on_output.pattern: ^[0-9]{4}-[0-9]{2}-[0-9]{2}T|^ERROR:
  notify_on_output.reason: agmsg inbox stream
EOF
}

agmsg_delivery_stop_directive() {
  cat <<'EOF'

AGMSG-DIRECTIVE: If a background Shell titled "agmsg inbox stream" is running, stop it.
EOF
}
