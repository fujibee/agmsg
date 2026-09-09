<!-- Claude Code overlay for the shared SKILL.md. -->

<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. **REQUIRED — Do NOT skip this step.** Ask the user to pick `monitor`, `turn`, `both`, or `off` delivery. Empty input means `monitor`.
     Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"` and follow the printed `AGMSG-DIRECTIVE` block.
<!-- /agmsg:slot delivery -->

<!-- agmsg:slot execute-extra -->
**Ensure monitor is running first.** In `monitor` or `both` mode, keep one persistent `watch.sh` task for this session. Switch that watcher when `actas` changes the active role.

Claude Code commands may need permission and sandbox allowlists for `~/.agents/skills/__SKILL_NAME__/scripts/` and its writable `db/`, `teams/`, and `run/` directories.

**Permission prompts.** Every command here runs through the Bash tool, so each call is gated by the permission system until the script directory is allowlisted. Without this the user is asked to confirm essentially every `__SKILL_NAME__` call. Add to `~/.claude/settings.json` (or project-level `.claude/settings.local.json`):

```json
{
  "permissions": {
    "allow": [
      "Bash(~/.agents/skills/__SKILL_NAME__/scripts/*)",
      "Bash(/Users/<you>/.agents/skills/__SKILL_NAME__/scripts/*)",
      "Bash(bash ~/.agents/skills/__SKILL_NAME__/scripts/*)",
      "Bash(bash /Users/<you>/.agents/skills/__SKILL_NAME__/scripts/*)"
    ]
  }
}
```

Four entries are needed because a rule matches the command string as written, and these scripts are invoked both as `~/...` and as an absolute path, with or without an explicit `bash` prefix. Replace `/Users/<you>` with the user's home directory.

**Sandbox compatibility.** When Claude Code's sandbox is enabled, `watch.sh` (monitor mode) runs inside the sandbox and needs to write pidfiles and SQLite WAL files under `~/.agents/skills/__SKILL_NAME__/`. If monitor mode fails with write/permission errors there, add an allowlist entry to `~/.claude/settings.json` (or project-level `.claude/settings.local.json`):

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": [
        "~/.agents/skills/__SKILL_NAME__/"
      ]
    }
  }
}
```

The allowlist does not enable sandboxing by itself. Use `/sandbox` in Claude Code to choose a sandbox mode, or add `"enabled": true` alongside `"filesystem"` under `"sandbox"` to configure it in settings. The allowlist has no effect until sandboxing is enabled.
<!-- /agmsg:slot execute-extra -->

<!-- agmsg:slot actas -->
If argument starts with "actas" followed by an agent name:
1. Resolve the role and claim its actas lock with `actas-claim.sh`.
2. Stop the old monitor task, then start `watch.sh` filtered to the new role when delivery is `monitor` or `both`.
3. Read `delivery.sh status` before reporting completion. If it returns `mode: off (no agmsg delivery hooks installed for this project)`, leave delivery stopped but tell the user that automatic delivery is not configured. Do not report `actas` as complete without saying this.
4. If it returns `mode: off (unrecognized: ...)`, leave delivery stopped and tell the user that the project configuration could not be identified. Do not report `actas` as complete without saying this.
5. Set the session's active FROM to the role and tell the user that receive is restricted to it.
<!-- /agmsg:slot actas -->

<!-- agmsg:slot drop -->
If argument starts with "drop" followed by an agent name:
1. Run `reset.sh "$(pwd)" __AGENT_TYPE__ <name> "$CLAUDE_CODE_SESSION_ID"` to release the role and its lock.
2. Run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`, then restart the default monitor subscription when the project is configured for `monitor` or `both`.
3. If it returns `mode: off (no agmsg delivery hooks installed for this project)`, leave delivery stopped but say so. Do not report the drop as complete without mentioning it.
4. If it returns `mode: off (unrecognized: ...)`, leave delivery stopped and explain that the project configuration could not be identified. Do not report the drop as complete without mentioning it.
<!-- /agmsg:slot drop -->

<!-- agmsg:slot spawn -->
If argument starts with "spawn": run `spawn.sh <type> <name> --project "$(pwd)" [options]`; it opens a pane and waits for a Claude Code watcher to attach. `despawn` sends `ctrl:despawn` and closes the spawned pane, or accepts `--force`.
<!-- /agmsg:slot spawn -->

<!-- agmsg:slot mode -->
If argument is "mode", run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"`.

For `mode monitor|turn|both|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"` and follow its `AGMSG-DIRECTIVE` block. Legacy `hook on` maps to `turn`; `hook off` maps to `off`.
<!-- /agmsg:slot mode -->
