---
name: agmsg
description: Cross-agent messaging via SQLite. Send messages between Claude Code, Codex, Gemini CLI, and other agents. No daemon, no network, no dependencies beyond bash and sqlite3.
---

# Agent Messaging

**IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

## How to use

### Step 1: Check identity

```bash
~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" <type>
# type: claude-code, codex, gemini
# Returns: agent=... / multiple=true ... / suggest=true ... / not_joined=true ...
```

### Step 2a: If not in a team — join one

Ask the user for a team name and agent name, then run:

```bash
~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> <type> "$(pwd)"
```

Do NOT manually edit config files. Always use join.sh.

### Step 2b: If already in a team — execute command

**Default (no arguments): IMMEDIATELY check inbox. Do NOT ask what to do.**

```bash
# Check inbox (marks messages as read) — DEFAULT action
~/.agents/skills/__SKILL_NAME__/scripts/inbox.sh <team> <agent_id>

# Send a message
~/.agents/skills/__SKILL_NAME__/scripts/send.sh <team> <from_agent> <to_agent> "<message>"

# Message history
~/.agents/skills/__SKILL_NAME__/scripts/history.sh <team> [agent_id] [limit]

# List team members
~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team>

# Leave a team
~/.agents/skills/__SKILL_NAME__/scripts/leave.sh <team> <agent_id>

# Clear registrations for the current project/type
~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" <type> [agent_id]

# Enable/disable auto message checking (hook)
~/.agents/skills/__SKILL_NAME__/scripts/hook.sh on <type> "$(pwd)"
~/.agents/skills/__SKILL_NAME__/scripts/hook.sh off <type> "$(pwd)"
```

## Architecture

- **Storage**: SQLite with WAL mode in `~/.agents/skills/__SKILL_NAME__/db/messages.db`
- **Teams**: `~/.agents/skills/__SKILL_NAME__/teams/<name>/config.json`
- **Concurrency**: WAL allows multiple readers + 1 writer without conflicts
- **No daemon**: Direct DB access via `sqlite3` CLI
- **Dependencies**: bash, sqlite3 (no python3 required)
