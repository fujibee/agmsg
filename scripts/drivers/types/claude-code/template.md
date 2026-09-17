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
If argument starts with "actas" followed by an agent name (e.g. "actas alice"):
1. Parse the new role name. If none was given (e.g. bare "actas", or the user asks you to suggest one), run `~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team>` for each TEAM to see the current roster. Look for a naming convention already in play (e.g. a shared base name with role and number suffixes (`<base>-<role><n>`), or names derived from the team name) and, when one exists, propose 2-3 unused names that extend it; otherwise propose 2-3 short, distinctive identity names (not a bare tool-type label). Either way, names must not collide with the roster. Ask the user to pick one or type their own before continuing.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" __AGENT_TYPE__` to see whether the role is already registered for this (project, type).
3. If the name does not appear in the output, join under the existing team. Read TEAMS from the in-session whoami state (it may be a single team or comma-separated). For a single team, run `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> __AGENT_TYPE__ "$(pwd)"`. For multiple teams, ask the user which team to join the new role into, then run join.sh for that team.
4. **Pre-flight claim** the actas exclusivity lock so this role isn't already owned by another live session: `~/.agents/skills/__SKILL_NAME__/scripts/actas-claim.sh "$(pwd)" __AGENT_TYPE__ <name> "$CLAUDE_CODE_SESSION_ID"`. Read the `status=` line of the output:
    - `status=ok ...`: proceed to step 5.
    - `status=held team=<team> owner=<sid>`: another live session currently owns `<name>` in `<team>`. Tell the user: "Cannot actas as `<name>` — it is held by session `<sid>` in team `<team>`. Run `/__SKILL_NAME__ drop <name>` in that session first, then retry." Then abort — do NOT touch the running Monitor.
    - `status=not_registered`: shouldn't happen if step 3 ran; treat as an error.
5. **Switch receive too — exclusive role mode.**
   a. Run TaskList. Find any task whose description begins with "agmsg inbox stream".
   b. **If a matching task is found**: TaskStop it.
   c. **If no matching task is found** (typical when /__SKILL_NAME__ actas runs as the first command of a fresh session — SessionStart hasn't fired the Monitor directive yet, or you're invoking actas before the agent acted on it): skip TaskStop entirely. There is no Monitor to stop. Do NOT attempt TaskStop with a guessed or empty task_id — it will fail with "Invalid tool parameters" and confuse the flow.
   d. Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"` and read its **first line**.
      - **`mode: monitor` or `mode: both`**: invoke a fresh Monitor, regardless of whether step b or c applied:
        - command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" __AGENT_TYPE__ <name>`
        - description: `agmsg inbox stream (acting as <name>)`
        - persistent: true
      - **`mode: turn`**: leave it stopped, silently. `has_st=1` is the one case `delivery.sh` can actually confirm was a deliberate choice — someone configured turn-based delivery for this project — so `actas` starting nothing here needs no explanation.
      - **`mode: off (no agmsg delivery hooks installed for this project)`**: leave it stopped (`actas` must not start automatic delivery a project wasn't configured for), but **do not treat this as silently deliberate**. `delivery.sh` cannot tell whether someone ran `mode off` here or this project was simply never configured — both leave the exact same settings file (#687 review round 3). **Tell the user** — e.g. "agmsg delivery hooks are not installed for this project; automatic delivery remains stopped. Run `/__SKILL_NAME__ mode <choice>` if you want to configure it." Keep it matter-of-fact, not a warning. Do not report `actas` as complete without saying this.
      - **`mode: off (unrecognized: ...)`**: leave it stopped too (same rule — do not guess a mode), but this is a stronger case than the no-hooks-installed one above: `delivery.sh` could not even find or read a settings file for this project, most often because the working directory does not match how the project was actually registered. **Tell the user explicitly** — e.g. "agmsg could not find a delivery configuration for this project at `<path from the message>` — delivery is stopped, but this may mean the project isn't registered here rather than that it was deliberately turned off. Check the path, or run `/__SKILL_NAME__ mode <choice>` to configure it explicitly." Do not report `actas` as complete without saying this — a silent stop here is indistinguishable from the other off cases and is what let this go unnoticed before (#687).
   The 4th argument to `watch.sh` restricts the subscription to messages addressed to `<name>` only — other roles' inbound messages stop reaching this session until another `actas` or session end.
6. Set the session's active FROM to `<name>` — use `<name>` in every `send.sh` call for the rest of this session.
7. Tell the user: "Now acting as `<name>`. Sends use `<name>` as from; receive restricted to `<name>` only."
8. **Only if this session was NOT launched via `spawn`** — check the environment variable `AGMSG_SPAWNED` (e.g. `printenv AGMSG_SPAWNED`): `spawn` exports `AGMSG_SPAWNED=1` and already named the session `<team>-<agent>` via `-n`, so when it is set, **skip this tip entirely**. When it is UNSET (a human typed `claude` then actas'd, so the session has no convention name), additionally suggest to the user: "Tip: rename this session to `<team>-<name>` with `/rename <team>-<name>` so it's easy to find in the `/resume` picker and stays labeled after a restart." `/rename` is a user-typed slash command — you cannot invoke it yourself, so only suggest it.
9. **Confirm the Monitor actually attached** — only when step 5d invoked a fresh Monitor (`mode: monitor` or `mode: both`): run TaskList once more and confirm a task whose description begins with `agmsg inbox stream` is present. Do NOT read this off the terminal UI's background-task footer — it does not reliably reflect whether a Monitor is really streaming for this session; TaskList is the only check that does. If the task is missing, retry the Monitor invocation from step 5d once. If it is still missing after the retry, tell the user `actas` completed but delivery could not be confirmed as attached, and do not describe delivery as active.
<!-- /agmsg:slot actas -->

<!-- agmsg:slot drop -->
If argument starts with "drop" followed by an agent name (e.g. "drop alice"):
1. Parse the role name.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" __AGENT_TYPE__ <name> "$CLAUDE_CODE_SESSION_ID"` to remove only that role's registration for this project. If the role has no other registrations left, reset.sh also drops it from the team config. The 4th argument releases any actas exclusivity locks this session held on the role so peers can pick it up immediately (see #62).
3. If the session's active FROM was `<name>`, clear that state. Then:
   a. Run TaskList. Find any task whose description begins with "agmsg inbox stream".
   b. **If a matching task is found**: TaskStop it.
   c. **If no matching task is found**: skip TaskStop. Do NOT attempt TaskStop with a guessed or empty task_id.
   d. Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"` and read its **first line**.
      - **`mode: monitor` or `mode: both`**: invoke a fresh Monitor with the default subscription (no `actas` name filter — receives every (team, agent) pair currently registered for this project that isn't held by another session):
        - command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" __AGENT_TYPE__`
        - description: `agmsg inbox stream`
        - persistent: true
      - **`mode: turn`**: leave it stopped, silently — the one case `delivery.sh` can confirm was deliberate.
      - **`mode: off (no agmsg delivery hooks installed for this project)`**: leave it stopped, but say so — same reasoning as the `actas` step this mirrors: this state is indistinguishable from "never configured" (#687 review round 3), so do not report it as deliberate. Do not report the drop as complete without mentioning it.
      - **`mode: off (unrecognized: ...)`**: leave it stopped, but say so with the stronger diagnostic — same reasoning as the `actas` step this mirrors (#687). Do not report the drop as complete without mentioning it.
4. Tell the user: "Dropped role `<name>` from this project."
<!-- /agmsg:slot drop -->

<!-- agmsg:slot spawn -->
If argument starts with "spawn" (e.g. "spawn codex reviewer", "spawn claude-code alice --window"):
1. Parse `<type>` (a spawnable agent type), `<name>`, and any options (`--boot-prompt <text>`, `--project <path>`, `--team <team>`, `--window`, `--split h|v`, `--terminal <template>`, `--no-wait`, `--ready-timeout <secs>`, `--model <id>`, `--fresh`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/spawn.sh <type> <name> --project "$(pwd)" [options]`
   - `spawn.sh` pre-joins `<name>`, then opens a new pane or window through the terminal driver and launches the target CLI with `/__SKILL_NAME__ actas <name>` as its initial prompt. `--boot-prompt` appends a first task to that prompt. Which terminal that is is the driver's decision, never something to name here.
   - By default it blocks until a spawned Claude Code agent's watcher attaches and prints `status=ready`; `--no-wait` returns immediately. A spawned Codex agent has no Monitor and skips the readiness wait.
   - It refuses early when `<name>` is already held by another live session, the target CLI is missing, the project path is invalid, or the terminal driver has nowhere to place it.
3. Show the script's output. Do not TaskStop or relaunch this session's own Monitor; spawn affects a separate agent.

If argument starts with "despawn" (e.g. "despawn reviewer", "despawn alice --force"):
1. Parse `<name>` and any options (`--force`, `--timeout <secs>`). `despawn` tears down a member previously spawned by this session.
2. Determine which team `<name>` belongs to, then run:
   `~/.agents/skills/__SKILL_NAME__/scripts/despawn.sh <team> $AGENT <name> [--force] [--timeout <secs>]`
   - The default graceful path sends a `ctrl:despawn` message; the member's watcher drops its role and closes its spawned pane, then `despawn` waits for the lock to release.
   - If the member is Codex and has no watcher, or graceful teardown times out, use `--force` to tear down the recorded pane/window and drop the registration directly.
3. Show the script's output. Do not TaskStop or relaunch this session's own Monitor.
<!-- /agmsg:slot spawn -->

<!-- agmsg:slot mode -->
If argument is "mode", run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"`. Show the output to the user. If it says `mode: monitor`, explicitly say this is only configuration status; runtime success still requires Claude Code's generic `Monitor(agmsg inbox stream)` task, footer `1 monitor`, and transcript `Monitor event: "agmsg inbox stream"`.

For `mode monitor|turn|both|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"` and follow its `AGMSG-DIRECTIVE` block. Legacy `hook on` maps to `turn`; `hook off` maps to `off`.
<!-- /agmsg:slot mode -->
