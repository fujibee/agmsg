---
name: __SKILL_NAME__
description: Cross-agent messaging via SQLite. Send messages between Claude Code, Codex, Gemini CLI, Hermes Agent, and other agents. No daemon, no network, no dependencies beyond bash and sqlite3.
---

Hermes Agent skill for agmsg cross-agent messaging. **IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

**Shell requirement:** All agmsg scripts are Bash scripts. Always execute them via `bash`, never via PowerShell or cmd directly. If your default shell is not Bash (e.g. PowerShell on Windows), wrap every command with `bash -lc '...'`. Example: `bash -lc '~/.agents/skills/__SKILL_NAME__/scripts/send.sh myteam alice bob "hello"'`. Do NOT construct DB paths manually — the scripts handle path resolution internally. If you need to redirect storage, use `AGMSG_STORAGE_PATH` (the supported override).

## Identity

If you already know your AGENT and TEAMS from a previous `/__SKILL_NAME__` use in this session, skip to **Execute** below.

Otherwise, run: `~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" hermes`

Four possible outputs:

**A) Single identity:**
`agent=<name> teams=<t1,t2,...> type=hermes project=<path>`
→ Remember AGENT and TEAMS, then go to **Execute**.

**B) Multiple identities:**
`multiple=true agents=<n1,n2,...> teams=<t1,t2,...> type=hermes project=<path>`
→ Ask the user which agent name to use for this session, then go to **Execute**.

**C) Not in a team:**
`not_joined=true available_teams=<t1,t2,...>` (or `available_teams=none`)
→ Show the user the available teams from the output, then:

  > **First-time setup required.**
  > Joining a team so this agent can send and receive messages.
  > - **Team name**: a group of agents that can message each other (available: <list from output>)
  > - **Agent name**: this agent's identity within the team

  1. Ask: "Enter a team name (joins existing or creates new)"
  2. If the team name given already appears in `available_teams`, run `~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team>` to see the current roster (name, type, project) and note the names already in use. Look for a naming convention already in play (e.g. a shared base name with role/number suffixes like `aggie-cc1`/`aggie-cc2`, or names derived from the team name) and, when one exists, propose 2-3 unused names that extend it; otherwise propose 2-3 short, distinctive identity names (not a bare tool-type label like `codex`/`cc`). Either way, names must not collide with the roster. Then ask: "Enter a name for this agent (suggestions: <name1>, <name2>, <name3> — or type your own)". For a brand-new team, skip the roster check and just ask: "Enter a name for this agent".
  3. **You MUST use join.sh** — run: `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> hermes "$(pwd)"`
  4. Show the result and explain:

  > **Joined!** You can now use `/__SKILL_NAME__` to check and send messages.
  > - ask to check inbox — check unread messages
  > - ask `send <agent> <message>` — send a message
  > - ask `team` — list team members
  > - ask `history` — message history

  5. Hermes has no agmsg automatic delivery hook. Set manual delivery explicitly:
     `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set off hermes "$(pwd)"`

  6. Then check inbox for the newly joined team.

**D) Suggestions for reuse:**
`suggest=true agents=<n1,n2,...> teams=<t1,t2,...> type=hermes project=<path> available_teams=<t1,t2,...>`
→ No exact registration exists for this project, but there are same-type agent names registered elsewhere.

  1. Show the suggested agent names to the user.
  2. Ask whether to reuse one of those names or choose a new one.
  3. Ask for the team name to join (existing or new).
  4. Run: `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> hermes "$(pwd)"`
  5. Then continue with the normal post-join flow above.

## Execute

**Only use scripts in `~/.agents/skills/__SKILL_NAME__/scripts/` — do not read or modify files under `teams/` or `db` directly.**

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

If argument is "config":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh show`
2. Show the output to the user.

If argument starts with "config set" (e.g. "config set hook.check_interval 30"):
1. Parse key and value from the arguments.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh set <key> <value>`

If argument starts with "actas" followed by an agent name (e.g. "actas alice"):
1. Parse the new role name. If none was given (e.g. bare "actas", or the user asks you to suggest one), run `~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team>` for each TEAM to see the current roster. Look for a naming convention already in play (e.g. a shared base name with role/number suffixes like `aggie-cc1`/`aggie-cc2`, or names derived from the team name) and, when one exists, propose 2-3 unused names that extend it; otherwise propose 2-3 short, distinctive identity names (not a bare tool-type label). Either way, names must not collide with the roster. Ask the user to pick one or type their own before continuing.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" hermes` to see whether the role is already registered for this (project, type).
3. If the name does not appear in the output, join under the existing team. For a single team, run `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> hermes "$(pwd)"`. For multiple teams, ask the user which team to join the new role into.
4. Set the session's active FROM to `<name>` for every `send.sh` call until another `actas`.
5. Tell the user: "Now acting as `<name>`. Sends will use `<name>` as the from agent."

If argument starts with "drop" followed by an agent name (e.g. "drop alice"):
1. Parse the role name.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" hermes <name>` to remove that role's registration.
3. If the session's active FROM was `<name>`, clear that state.
4. Tell the user: "Dropped role `<name>` from this project."

If argument starts with "spawn" (e.g. "spawn claude-code alice", "spawn codex reviewer --window"):
1. Parse `<type>` (must be `claude-code` or `codex` — `hermes` itself is not spawnable via this command; its CLI has no mode that starts an interactive session pre-seeded with an initial prompt, #279), `<name>`, and any options (`--project`, `--team`, `--window`, `--split h|v`, `--terminal`, `--no-wait`, `--ready-timeout <secs>`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/spawn.sh <type> <name> --project "$(pwd)" [options]`
3. Show the script's output.

If argument is "mode" (no further args):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status hermes "$(pwd)"`
2. Show the output to the user.

If argument starts with "mode" followed by a mode name (e.g. "mode off"):
1. Parse the mode. Hermes supports only `off`.
2. If the requested mode is `off`, run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set off hermes "$(pwd)"`
3. If the requested mode is `monitor`, `both`, or `turn`, do not run a command; tell the user: "Hermes has no agmsg automatic delivery hook; only `off` mode is supported."

If argument is "hook on" (legacy alias):
1. Tell the user: "Hermes has no agmsg automatic delivery hook; use manual inbox checks."

If argument is "hook off" (legacy alias):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set off hermes "$(pwd)"`
2. Tell the user: "Delivery mode set to 'off'."

If argument is "reset":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" hermes`
2. Tell the user the result.
