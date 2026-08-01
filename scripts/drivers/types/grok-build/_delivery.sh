#!/usr/bin/env bash
# grok-build delivery plug — markdown rule file (.grok/rules/agmsg.md) plus an
# opt-in, explicitly-launched monitor watcher.
#
# Why a rule file (not a hook): Grok Build's passive hooks (SessionStart/Stop)
# discard their stdout — they cannot inject anything into the conversation. A
# Stop hook running check-inbox.sh would therefore deliver NOTHING while still
# marking messages read = silent loss. So the baseline integration is a markdown
# rule under <project>/.grok/rules/, which Grok always scans into context each
# turn. The rule tells the agent to poll its own inbox; the agent runs the check
# as a tool call and reads the output — the simplest delivery path Grok supports.
#
# monitor mode (opt-in): Grok Build DOES expose a `monitor` background-task tool
# (monitor(command, description, persistent:true)) that accumulates a long-running
# command's stdout and injects each line back into the conversation as a
# notification — the same shape as Claude Code's Monitor tool. Running watch.sh
# under it gives real-time delivery. The ONLY difference from claude-code is that
# Grok's passive hooks cannot auto-launch it at SessionStart, so the launch is
# explicit: the rule (and the /agmsg actas flow) instruct the agent to start the
# watcher via the monitor tool. turn stays the zero-setup default; monitor is
# additive.
#
# The rule points at inbox.sh (not check-inbox.sh): inbox.sh prints the unread
# messages in plain text AND marks them read in the same call, so the agent sees
# exactly what gets consumed (loss-safe). check-inbox.sh wraps its output in
# Claude hook-control JSON and carries hook-only cooldown/watcher logic that is
# wrong for an agent reading tool output.
#
# Rule files need no folder-trust (Grok's trust gate is for execution —
# hooks/MCP/LSP — not rules), and a project-level .grok/rules is read even
# outside a git repo, so this also works for spawned sessions.
# delivery_modes is "turn monitor off". A marker comment at the top of the rule
# records which mode wrote it so status can tell turn from monitor.
# Uses resolve_hooks_file + SKILL_DIR + RUN_DIR from delivery.sh's sourced context.

agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")

  # Always start clean; turn/monitor rewrite the rule, off leaves it absent.
  rm -f "$rule_file"

  case "$mode" in
    turn)
      mkdir -p "$(dirname "$rule_file")"
      cat <<EOF > "$rule_file"
<!-- agmsg-delivery-mode: turn -->
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

There is no background watcher in turn mode — this self-check is how delivery
works. Removing this file turns automatic delivery off.
EOF
      ;;
    monitor)
      mkdir -p "$(dirname "$rule_file")"
      # The watch.sh command below passes "${GROK_SESSION_ID:--}" (sentinel `-`),
      # NOT "$GROK_SESSION_ID": Grok's monitor tool re-evaluates the command
      # line, and a quoted-but-empty expansion is dropped entirely there —
      # shifting project/type/name one slot left and leaving the watcher
      # subscribed to nothing. `-` survives the re-eval as a real argument and
      # watch.sh folds it into its empty-session-id resolution path.
      cat <<EOF > "$rule_file"
<!-- agmsg-delivery-mode: monitor -->
# agmsg — keep a real-time inbox watcher running

You belong to one or more agmsg teams. Incoming messages are delivered in real
time by the \`monitor\` tool, which streams each new message into THIS
conversation as a notification.

> Launch with the \`monitor\` tool ONLY. The \`monitor\` tool is the only thing
> that surfaces watcher output to you. Do NOT start the watcher with
> \`run_terminal_command\` (with or without \`background: true\`), and do NOT roll
> your own \`tail -f\` of a log file. A terminal/background command writes the
> stream to a log you never see, so messages keep arriving but you silently miss
> every one of them — and stray watcher tasks pile up. If unsure which tool you
> used, you used the wrong one unless it was literally \`monitor\`.

At the start of each session (and any time no agmsg watcher is running), launch
it once:

1. Identify yourself if you have not already:
   \`$SKILL_DIR/scripts/whoami.sh '$project' $type\`
   It prints your \`agent=\` name and \`teams=\` list.
2. Start the watcher with the \`monitor\` tool (that exact tool — not
   \`run_terminal_command\`), persistent, so each new message streams into the
   conversation as a notification. Pass these three fields verbatim:
   - command: \`$SKILL_DIR/scripts/watch.sh "\${GROK_SESSION_ID:--}" '$project' $type\`
   - description: \`agmsg inbox stream\`
   - persistent: true
   Use the command EXACTLY as written. Do NOT append \`| head\`, \`| tail\`, any
   other pipe, or a redirection: each watcher line is one message, and a closed
   pipe (e.g. \`head\` exiting after N lines) makes the watcher's writes fail so
   messages after the Nth are dropped silently.
3. Verify it attached: a \`monitor\` task named \`agmsg inbox stream\` should now
   be listed and streaming. If you do not see a live \`monitor\` task (e.g. you
   ran the command as a terminal/background command by mistake), stop whatever
   you started and relaunch via the \`monitor\` tool — otherwise no message will
   ever reach you.
4. Each notification line is one message:
   \`<ts> | <team> | <from> -> <to> | <body>\`. React as they arrive; reply with
   \`$SKILL_DIR/scripts/send.sh <team> <your-agent-name> <to_agent> "<message>"\`.

Launch it only once per session — if a watcher is already streaming, do not
start a second one. Stopping is via the \`kill_command_or_subagent\` tool on the
watcher's task id. Removing this file turns automatic delivery off.
EOF
      ;;
    off)
      : # rule file already removed
      ;;
  esac
}

# Enabling monitor: nudge the CURRENT session to launch the watcher now (the
# rule above re-declares it for future turns/sessions). Mirrors claude-code's
# in-session directive, but worded for Grok's `monitor` tool since there is no
# SessionStart hook to auto-launch it.
agmsg_delivery_on_enable() {
  local mode="$1" type="$2" project="$3"
  [ "$mode" = "monitor" ] || return 0
  echo "Future sessions: the .grok/rules/agmsg.md rule will prompt the watcher launch (Grok has no SessionStart auto-start)."
  _agmsg_grok_emit_monitor_directive "$type" "$project"
}

# Grok-flavored stop directive (overrides the default Claude TaskStop wording).
agmsg_delivery_stop_directive() {
  cat <<'EOF'

AGMSG-DIRECTIVE: If an agmsg inbox watcher is streaming into this session via
the monitor tool, stop it with kill_command_or_subagent on its task id. Any
watch.sh processes have already been killed by this command.
EOF
}

# Status: the rule file's marker is the state. Absent => off; a monitor marker
# => monitor; anything else (a present rule) => turn.
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

# Emit the in-session "launch the watcher now" directive for Grok. Mirrors
# delivery.sh's emit_monitor_directive (claude-code) but bakes GROK_SESSION_ID
# and points at Grok's monitor tool. Reuses the shared instance-id normalization
# and the dup-watcher guard so a second `set monitor` does not orphan a live
# watcher.
_agmsg_grok_emit_monitor_directive() {
  local type="$1" project="$2"
  local watch="$SKILL_DIR/scripts/watch.sh"

  # Bake GROK_SESSION_ID in when it is set here, so the agent does not invent a
  # value and cleanup can find the pidfile. NOTE: Grok does NOT reliably export
  # GROK_SESSION_ID into the `monitor` tool's own shell — that is why the rule
  # passes "${GROK_SESSION_ID:--}": when unset it resolves to the sentinel `-`,
  # which watch.sh folds into its empty-arg path and self-generates a fallback
  # id rather than failing (a bare empty "" would be dropped by the re-eval and
  # shift the remaining arguments). This directive path still bakes the real id
  # when delivery.sh runs with it in the env.
  local session_id="${GROK_SESSION_ID:-}"
  if [ -z "$session_id" ]; then
    session_id="agmsg-$(compat_uuidgen | tr 'A-Z' 'a-z')"
  fi
  session_id="$(agmsg_normalize_instance_id "$session_id" "$type")"

  local pidfile="$RUN_DIR/watch.$session_id.pid"
  if [ -f "$pidfile" ]; then
    local existing
    existing=$(cat "$pidfile" 2>/dev/null || true)
    # _agmsg_pid_alive_local, mirroring delivery.sh emit dedup: the recorded pid is
    # watch.sh's own $$, which tasklist cannot see (#567).
    if [ -n "$existing" ] && _agmsg_pid_alive_local "$existing"; then
      cat <<EOF

A watch.sh is already streaming into this session (pid $existing). No
action needed — the existing watcher is the active one.
EOF
      return 0
    fi
  fi

  local watch_command
  watch_command="$(printf '%q %q %q %q' "$watch" "$session_id" "$project" "$type")"
  cat <<EOF

AGMSG-DIRECTIVE: For this running session, invoke the monitor tool now with:
  command: $watch_command
  description: agmsg inbox stream
  persistent: true

Pass the command above verbatim — the session id is already filled in. Each
output line is one message; stop the watcher with kill_command_or_subagent on
its task id when you switch roles or turn delivery off.
EOF
}
