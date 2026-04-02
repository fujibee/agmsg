---
description: Agent messaging — check inbox, send messages, view history
---

Agent messaging command. **IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

## Step 1: Identity check

Run: `~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" codex`

Three possible outputs:

**A) Single identity:**
`agent=<name> teams=<t1,t2,...> type=codex project=<path>`
→ Go to Step 2.

**B) Multiple identities:**
`multiple=true agents=<n1,n2,...> teams=<t1,t2,...> type=codex project=<path>`
→ Ask the user which agent name to use for this session, then proceed to Step 2.

**C) Not in a team:**
`not_joined=true available_teams=<t1,t2,...>` (or `available_teams=none`)
→ Show the user the available teams from the output, then:

  > **First-time setup required.**
  > Joining a team so this agent can send and receive messages.
  > - **Team name**: a group of agents that can message each other (available: <list from output>)
  > - **Agent name**: this agent's identity within the team

  1. Ask: "Enter a team name (joins existing or creates new)"
  2. Ask: "Enter a name for this agent"
  3. **You MUST use join.sh** — run: `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> codex "$(pwd)"`
  4. Show the result and explain:

  > **Joined!** You can now use `$__SKILL_NAME__` to check and send messages.
  > - `$__SKILL_NAME__` — check inbox
  > - `$__SKILL_NAME__ send <agent> <message>` — send a message
  > - `$__SKILL_NAME__ team` — list team members
  > - `$__SKILL_NAME__ history` — message history

  Then check inbox for the newly joined team.

## Step 2: Execute command (after joining a team)

Parse AGENT from `agent=` and TEAMS from `teams=` (comma-separated) in the whoami output.
If in multiple teams, operate on ALL teams unless the user specifies one.

**Only use scripts in `~/.agents/skills/__SKILL_NAME__/scripts/` — do not read or modify files under `teams/` or `db/` directly.**

If no arguments provided:
1. For each TEAM, run: `~/.agents/skills/__SKILL_NAME__/scripts/inbox.sh $TEAM $AGENT`
2. If there are messages, read and respond appropriately. To reply:
   `~/.agents/skills/__SKILL_NAME__/scripts/send.sh $TEAM $AGENT <to_agent> "<message>"`

If argument is "history":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/history.sh $TEAM $AGENT`

If argument is "team":
1. For each TEAM, run: `~/.agents/skills/__SKILL_NAME__/scripts/team.sh $TEAM`

If argument starts with "send" (e.g. "send misaki check the server"):
1. Parse target agent and message from the arguments
2. Determine which team the target agent belongs to, then run:
   `~/.agents/skills/__SKILL_NAME__/scripts/send.sh $TEAM $AGENT <to_agent> "<message>"`
