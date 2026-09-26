<!-- Codex overlay for the shared SKILL.md. -->

<!-- agmsg:slot shell-extra -->
On Windows PowerShell, invoke Git Bash explicitly and keep the full `bash -lc` payload inside one single-quoted string:

`& 'C:\Program Files\Git\bin\bash.exe' -lc '~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" codex'`

Do not use POSIX `'"'"'` quote splicing in PowerShell, and do not use escaped double quotes inside the wrapper.
<!-- /agmsg:slot shell-extra -->

<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
**Sending a message:** pass the body on stdin with `--stdin`. It reads it verbatim from a file descriptor, so nothing you write is re-parsed by a shell or capped by an argv limit. The older positional form — `send.sh <team> <from> <to> "<message>"` — is **deprecated** (#378): your shell parses that message before agmsg ever sees it, so backticks or `$(...)` in the body can be evaluated there, and on Windows a long body is silently truncated at 8186 bytes. **A message you compose MUST NOT use the positional form.** If the body is literally `--`, `--stdin`, or `--force`, put `--` in front of it: `send.sh <team> <from> <to> -- --stdin` — and for a body of `--`, that is `-- --`. Pick a heredoc delimiter the body cannot contain on a line by itself — a body with a bare `AGMSG_BODY` line would end the heredoc early and the rest would run as shell commands.
  5. **REQUIRED — Do NOT skip this step.** Ask the user to pick `monitor`, `turn`, or `off` delivery. Empty input means `monitor`.
     Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`.
     Monitor uses the Codex app-server bridge; it changes how `codex` starts and is documented in `docs/codex-monitor-beta.md`.
<!-- /agmsg:slot delivery -->

<!-- agmsg:slot actas -->
If argument starts with "actas" followed by an agent name:
1. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" __AGENT_TYPE__`. If `<name>` is not listed, join with `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> __AGENT_TYPE__ "$(pwd)"`.
2. Record the Codex thread so a later spawn can resume it: `~/.agents/skills/__SKILL_NAME__/scripts/drivers/types/codex/codex-record-session.sh <team> <name>`. Both arguments are required; `<team>` is the team `<name>` belongs to (from step 1). Without them nothing is recorded and the monitor cannot deliver to this thread.
3. Use the role as the active FROM; monitor delivery is routed only to its recorded thread.
<!-- /agmsg:slot actas -->

<!-- agmsg:slot drop -->
If argument starts with "drop", run `reset.sh "$(pwd)" __AGENT_TYPE__ <name>` and clear the role's recorded Codex seat.
<!-- /agmsg:slot drop -->

<!-- agmsg:slot spawn -->
If argument starts with "spawn" (e.g. "spawn claude-code alice", "spawn codex reviewer --window"):
1. Parse `<type>` (a spawnable agent type), `<name>`, and any options (`--boot-prompt <text>`, `--project <path>`, `--team <team>`, `--window`, `--split h|v`, `--terminal <template>`, `--no-wait`, `--ready-timeout <secs>`, `--model <id>`, `--fresh`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/spawn.sh <type> <name> --project "$(pwd)" [options]`
   - `spawn.sh` pre-joins `<name>`, then opens a new pane or window through the terminal driver and launches the target CLI with `$__SKILL_NAME__ actas <name>` as its initial prompt. `--boot-prompt` appends a first task to that prompt. Codex spawn uses the bundled shim and bridge. Which terminal that is is the driver's decision, never something to name here.
   - By default it blocks until a spawned Claude Code agent's watcher attaches and prints `status=ready`; `--no-wait` returns immediately. A spawned Codex agent has no Monitor and skips the readiness wait.
   - It refuses early when `<name>` is already held by another live session, the target CLI is missing, the project path is invalid, or the terminal driver has nowhere to place it.
3. Show the script's output.

If argument starts with "despawn" (e.g. "despawn reviewer", "despawn alice --force"):
1. Parse `<name>` and any options (`--force`, `--timeout <secs>`). `despawn` tears down a member previously spawned by this session.
2. Determine which team `<name>` belongs to, then run:
   `~/.agents/skills/__SKILL_NAME__/scripts/despawn.sh <team> $AGENT <name> [--force] [--timeout <secs>]`
   - The default graceful path sends a `ctrl:despawn` message so a Claude Code member's watcher drops its role and closes its spawned pane, then waits for the lock to release.
   - A Codex member has no watcher, so use `--force` for it. `--force` skips the message, tears down the recorded pane/window, and drops the registration directly.
3. Show the script's output.
<!-- /agmsg:slot spawn -->

<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.

For `mode monitor|turn|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`; `both` is unsupported. Legacy `hook on` maps to `turn`; `hook off` maps to `off`.
<!-- /agmsg:slot mode -->
