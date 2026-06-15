---
description: Agent messaging — check inbox, send messages, view history
---

Agent messaging command. **IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

## Identity

If you already know your AGENT and TEAMS from a previous `/__SKILL_NAME__` call in this session, skip to **Execute** below.

Otherwise, run: `~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" claude-code`

Four possible outputs:

**A) Single identity:**
`agent=<name> teams=<t1,t2,...> type=claude-code project=<path>`
→ Remember AGENT and TEAMS, then go to **Execute**.

**B) Multiple identities:**
`multiple=true agents=<n1,n2,...> teams=<t1,t2,...> type=claude-code project=<path>`
→ Ask the user which agent name to use for this session, then go to **Execute**.

**C) Not in a team:**
`not_joined=true available_teams=<t1,t2,...>` (or `available_teams=none`)
→ Show the user the available teams from the output, then:

  > **First-time setup required.**
  > Joining a team so this agent can send and receive messages.
  > - **Team name**: a group of agents that can message each other (available: <list from output>)
  > - **Agent name**: this agent's identity within the team

  1. Ask: "Enter a team name (joins existing or creates new)"
  2. Ask: "Enter a name for this agent"
  3. **You MUST use join.sh** — run: `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> claude-code "$(pwd)"`
  4. Show the result and explain:

  > **Joined!** You can now use `/__SKILL_NAME__` to check and send messages.
  > - `/__SKILL_NAME__` — check inbox
  > - `/__SKILL_NAME__ send <agent> <message>` — send a message
  > - `/__SKILL_NAME__ team` — list team members
  > - `/__SKILL_NAME__ history` — message history
  > - `/__SKILL_NAME__ mode <monitor|turn|both|off>` — switch delivery mode
  > - `/__SKILL_NAME__ actas <name>` — switch to another role in this project (creates if needed)
  > - `/__SKILL_NAME__ drop <name>` — remove a role from this project
  > - `/__SKILL_NAME__ spawn <type> <name>` — launch a new agent in a tmux pane / terminal and have it actas <name>

  5. **REQUIRED — Do NOT skip this step.** Ask the user to pick a delivery mode using exactly this prompt:

     ```
     Choose delivery mode for incoming messages:

       1) monitor — Real-time push (~5s latency)
                     SessionStart hook + Monitor tool streams events.
                     Recommended.

       2) turn    — Check inbox at the end of each assistant turn
                     Stop hook pulls after each response.

       3) both    — monitor primary, turn as fallback
                     Redundant safety net.

       4) off     — No automatic delivery
                     Manual /__SKILL_NAME__ only.

     [1]:
     ```

     - **Wait for the user's answer before proceeding.** Empty input means `1` (monitor).
     - Map the chosen number to a mode and run:
       `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> claude-code "$(pwd)"`
     - Read the `AGMSG-DIRECTIVE` block printed by `delivery.sh` and follow it (invoke Monitor or TaskStop as instructed).

  6. Then check inbox for the newly joined team.

**D) Suggestions for reuse:**
`suggest=true agents=<n1,n2,...> teams=<t1,t2,...> type=claude-code project=<path> available_teams=<t1,t2,...>`
→ No exact registration exists for this project, but there are same-type agent names registered elsewhere.

  1. Show the suggested agent names to the user.
  2. Ask whether to reuse one of those names or choose a new one.
  3. Ask for the team name to join (existing or new).
  4. Run: `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> claude-code "$(pwd)"`
  5. Then continue with the normal post-join flow above.

## Execute

**Only use scripts in `~/.agents/skills/__SKILL_NAME__/scripts/` — do not read or modify files under `teams/` or `db/` directly.**

**Ensure monitor is running first.** Before processing any subcommand below, check whether this session already has an `agmsg inbox stream` Monitor task in its TaskList. If not, and the project's delivery mode is `monitor` or `both` (check via `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status claude-code "$(pwd)"`), invoke the Monitor tool now:

- command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" claude-code`
- description: `agmsg inbox stream`
- persistent: true

Then continue with the user's subcommand. This catches the case where the user invokes `/__SKILL_NAME__` as the first prompt before the SessionStart-hook directive has been acted on.

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

The allowlist merges across scopes and takes effect immediately — no restart needed. (The `BASH_SOURCE`-empty case under the sandbox — the Bash tool runs commands via pipe/eval, so `BASH_SOURCE[0]` is empty inside sourced functions — is handled internally: `watch.sh` resolves `SKILL_DIR` from `$0` and `storage.sh` falls back to it. No user configuration needed.)

**If no arguments provided (DEFAULT action — always do this when the command is invoked without arguments):**
1. **IMMEDIATELY** run inbox check for each TEAM: `~/.agents/skills/__SKILL_NAME__/scripts/inbox.sh $TEAM $AGENT`
2. Do NOT ask the user what to do — just run the inbox check.
3. If there are messages, read and respond appropriately. To reply:
   `~/.agents/skills/__SKILL_NAME__/scripts/send.sh $TEAM $AGENT <to_agent> "<message>"`

If argument is "history":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/history.sh $TEAM $AGENT`

If argument is "team":
1. For each TEAM, run: `~/.agents/skills/__SKILL_NAME__/scripts/team.sh $TEAM`

If argument starts with "send" (e.g. "send misaki check the server"):
1. Parse target agent and message from the arguments
2. Determine which team the target agent belongs to, then run:
   `~/.agents/skills/__SKILL_NAME__/scripts/send.sh $TEAM $AGENT <to_agent> "<message>"`

If argument starts with "actas" followed by an agent name (e.g. "actas alice"):
1. Parse the new role name.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" claude-code` to see whether the role is already registered for this (project, type).
3. If the name does not appear in the output, join under the existing team. Read TEAMS from the in-session whoami state (it may be a single team or comma-separated). For a single team, run `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> claude-code "$(pwd)"`. For multiple teams, ask the user which team to join the new role into, then run join.sh for that team.
4. **Pre-flight claim** the actas exclusivity lock so this role isn't already owned by another live session: `~/.agents/skills/__SKILL_NAME__/scripts/actas-claim.sh "$(pwd)" claude-code <name> "$CLAUDE_CODE_SESSION_ID"`. Read the `status=` line of the output:
    - `status=ok ...`: proceed to step 5.
    - `status=held team=<team> owner=<sid>`: another live session currently owns `<name>` in `<team>`. Tell the user: "Cannot actas as `<name>` — it is held by session `<sid>` in team `<team>`. Run `/__SKILL_NAME__ drop <name>` in that session first, then retry." Then abort — do NOT touch the running Monitor.
    - `status=not_registered`: shouldn't happen if step 3 ran; treat as an error.
5. **Switch receive too — exclusive role mode.**
   a. Run TaskList. Find any task whose description begins with "agmsg inbox stream".
   b. **If a matching task is found**: TaskStop it.
   c. **If no matching task is found** (typical when /__SKILL_NAME__ actas runs as the first command of a fresh session — SessionStart hasn't fired the Monitor directive yet, or you're invoking actas before the agent acted on it): skip TaskStop entirely. There is no Monitor to stop. Do NOT attempt TaskStop with a guessed or empty task_id — it will fail with "Invalid tool parameters" and confuse the flow.
   d. Invoke a fresh Monitor regardless of whether step b or c applied:
      - command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" claude-code <name>`
      - description: `agmsg inbox stream (acting as <name>)`
      - persistent: true
   The 4th argument to `watch.sh` restricts the subscription to messages addressed to `<name>` only — other roles' inbound messages stop reaching this session until another `actas` or session end.
6. Set the session's active FROM to `<name>` — use `<name>` in every `send.sh` call for the rest of this session.
7. Tell the user: "Now acting as `<name>`. Sends use `<name>` as from; receive restricted to `<name>` only."

If argument starts with "drop" followed by an agent name (e.g. "drop alice"):
1. Parse the role name.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" claude-code <name> "$CLAUDE_CODE_SESSION_ID"` to remove only that role's registration for this project. If the role has no other registrations left, reset.sh also drops it from the team config. The 4th argument releases any actas exclusivity locks this session held on the role so peers can pick it up immediately (see #62).
3. If the session's active FROM was `<name>`, clear that state. Then:
   a. Run TaskList. Find any task whose description begins with "agmsg inbox stream".
   b. **If a matching task is found**: TaskStop it.
   c. **If no matching task is found**: skip TaskStop. Do NOT attempt TaskStop with a guessed or empty task_id.
   d. Invoke a fresh Monitor with the default subscription (no `actas` name filter — receives every (team, agent) pair currently registered for this project that isn't held by another session):
      - command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" claude-code`
      - description: `agmsg inbox stream`
      - persistent: true
4. Tell the user: "Dropped role `<name>` from this project."

If argument starts with "spawn" (e.g. "spawn codex reviewer", "spawn claude-code alice --window"):
1. Parse `<type>` (must be `claude-code` or `codex`), `<name>`, and any options (`--project`, `--team`, `--window`, `--split h|v`, `--terminal`, `--no-wait`, `--ready-timeout <secs>`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/spawn.sh <type> <name> --project "$(pwd)" [options]`
   - spawn.sh pre-joins `<name>`, then opens a tmux pane/window (when this session is inside tmux) or a new OS terminal, and launches the target CLI with `/__SKILL_NAME__ actas <name>` as its initial prompt.
   - By default it BLOCKS until the new agent's watcher attaches and prints `status=ready` — so you can message `<name>` right away. It prints `status=timeout` and exits 3 if not ready within `--ready-timeout` (default 90s); pass `--no-wait` for fire-and-forget. Codex skips the wait (no Monitor).
   - It refuses early if `<name>` is already held by another live session, if the target CLI is not installed, or if there is no tmux and no usable terminal (headless).
3. Show the script's output. Do NOT TaskStop or relaunch this session's own Monitor — spawn affects a separate, newly launched agent, not this session's subscription.

If argument is "mode" (no further args):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status claude-code "$(pwd)"`
2. Show the output to the user.

If argument starts with "mode" followed by a mode name (e.g. "mode monitor"):
1. Parse the mode (one of `monitor`, `turn`, `both`, `off`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> claude-code "$(pwd)"`
3. Read the `AGMSG-DIRECTIVE` block in the command output and follow it (invoke Monitor or TaskStop as instructed).

If argument is "hook on" (legacy alias):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set turn claude-code "$(pwd)"`
2. Tell the user: "Delivery mode set to 'turn' (legacy hook on behavior). Consider using /__SKILL_NAME__ mode monitor for real-time push."

If argument is "hook off" (legacy alias):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set off claude-code "$(pwd)"`
2. Tell the user: "Delivery mode set to 'off'."

If argument is "config":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh show`
2. Show the output to the user.

If argument starts with "config set" (e.g. "config set hook.check_interval 30"):
1. Parse key and value from the arguments.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh set <key> <value>`

If argument is "version":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/version.sh`
2. Show the output — the installed version (git-describe provenance recorded at install time).

If argument is "reset":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" claude-code`
2. Tell the user the result.
