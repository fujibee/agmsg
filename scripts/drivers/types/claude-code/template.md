<!-- Claude Code overlay for the shared SKILL.md. -->

<!-- agmsg:slot delivery -->
  5. **REQUIRED — Do NOT skip this step.** Ask the user to pick `monitor`, `turn`, `both`, or `off` delivery. Empty input means `monitor`.
     Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"` and follow the printed `AGMSG-DIRECTIVE` block.
<!-- /agmsg:slot delivery -->

<!-- agmsg:slot execute-extra -->
**Ensure monitor is running first.** In `monitor` or `both` mode, keep one persistent `watch.sh` task for this session. Switch that watcher when `actas` changes the active role.

Claude Code commands may need permission and sandbox allowlists for `~/.agents/skills/__SKILL_NAME__/scripts/` and its writable `db/`, `teams/`, and `run/` directories.
<!-- /agmsg:slot execute-extra -->

<!-- agmsg:slot actas -->
If argument starts with "actas" followed by an agent name:
1. Resolve the role and claim its actas lock with `actas-claim.sh`.
2. Stop the old monitor task, then start `watch.sh` filtered to the new role when delivery is `monitor` or `both`.
3. Set the session's active FROM to the role and tell the user that receive is restricted to it.
<!-- /agmsg:slot actas -->

<!-- agmsg:slot drop -->
If argument starts with "drop" followed by an agent name:
1. Run `reset.sh "$(pwd)" __AGENT_TYPE__ <name> "$CLAUDE_CODE_SESSION_ID"` to release the role and its lock.
2. Run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`, then restart the default monitor subscription when the project is configured for `monitor` or `both`.
<!-- /agmsg:slot drop -->

<!-- agmsg:slot spawn -->
If argument starts with "spawn": run `spawn.sh <type> <name> --project "$(pwd)" [options]`; it opens a pane and waits for a Claude Code watcher to attach. `despawn` sends `ctrl:despawn` and closes the spawned pane, or accepts `--force`.
<!-- /agmsg:slot spawn -->

<!-- agmsg:slot mode -->
If argument is "mode", run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"`.

For `mode monitor|turn|both|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"` and follow its `AGMSG-DIRECTIVE` block. Legacy `hook on` maps to `turn`; `hook off` maps to `off`.
<!-- /agmsg:slot mode -->
