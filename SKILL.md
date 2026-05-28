---
name: agmsg
description: Cross-agent messaging via SQLite. Send messages between Claude Code, Codex, Gemini CLI, and other agents. No daemon, no network, no dependencies beyond bash and sqlite3.
---

# Agent Messaging

**IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

## How to use

### OpenCode

OpenCode provides `agmsg_*` custom tools (from `.opencode/tools/agmsg.ts`) for messaging.
Available tools: `agmsg_whoami`, `agmsg_join`, `agmsg_inbox`, `agmsg_send`, `agmsg_history`, `agmsg_team`, `agmsg_mode`.

**First-time setup:** Call `agmsg_whoami` → if not joined, ask user for team/agent → `agmsg_join` → ask for delivery mode → `agmsg_mode`.

**Daily use (no arguments):** Call `agmsg_inbox` for each team. Do NOT ask — just run it.

### Claude Code / Codex / Gemini CLI

### Step 1: Check identity

```bash
~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" <type>
# type: claude-code, codex, gemini, antigravity, opencode
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

# Rename a team (moves dir, updates config + messages).
# After renaming, each existing member should re-run whoami.sh to refresh
# their cached team name in any running session.
~/.agents/skills/__SKILL_NAME__/scripts/rename-team.sh <old_team> <new_team>

# Clear registrations for the current project/type
~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" <type> [agent_id]

# Enable/disable auto message checking (hook)
~/.agents/skills/__SKILL_NAME__/scripts/hook.sh on <type> "$(pwd)"
~/.agents/skills/__SKILL_NAME__/scripts/hook.sh off <type> "$(pwd)"
```

## Architecture

### OpenCode integration
The `.opencode/tools/agmsg.ts` file provides custom tools that wrap the agmsg shell scripts.
Install by copying or symlinking to the project's `.opencode/tools/` directory, or globally to `~/.config/opencode/tools/`.

### Storage

- **Storage**: SQLite with WAL mode in `~/.agents/skills/__SKILL_NAME__/db/messages.db`
- **Teams**: `~/.agents/skills/__SKILL_NAME__/teams/<name>/config.json`
- **Concurrency**: WAL allows multiple readers + 1 writer without conflicts
- **No daemon**: Direct DB access via `sqlite3` CLI
- **Dependencies**: bash, sqlite3 (no python3 required)
