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

  5. **REQUIRED — Do NOT skip this step.** Ask the user: "Enable auto message checking? When enabled, incoming messages are automatically detected after each response. You can turn it on/off anytime with `/__SKILL_NAME__ hook on/off`."
     - **Wait for the user's answer before proceeding.**
     - If yes: run `~/.agents/skills/__SKILL_NAME__/scripts/hook.sh on claude-code "$(pwd)"`
     - If no: skip

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

If argument is "hook on":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/hook.sh on claude-code "$(pwd)"`
2. Tell the user: "Auto message checking enabled."

If argument is "hook off":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/hook.sh off claude-code "$(pwd)"`
2. Tell the user: "Auto message checking disabled."

If argument is "config":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh show`
2. Show the output to the user.

If argument starts with "config set" (e.g. "config set hook.check_interval 30"):
1. Parse key and value from the arguments.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh set <key> <value>`

If argument is "reset":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" claude-code`
2. Tell the user the result.
