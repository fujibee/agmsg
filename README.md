# agmsg

Cross-agent messaging for CLI AI agents. No daemon, no network, no complexity.

Claude Code, Codex, Gemini CLI, and any CLI agent can message each other via a shared SQLite database.

## Quick Start

```bash
# 1. Install (one-liner)
bash <(curl -fsSL https://raw.githubusercontent.com/fujibee/agmsg/main/setup.sh)

# Or clone first if you want to inspect the code
git clone https://github.com/fujibee/agmsg.git && cd agmsg && ./install.sh

# 2. Restart Claude Code / Codex to pick up the new skill

# 3. Run the command — it will prompt for team and agent name on first use
#    Claude Code:  /agmsg
#    Codex:        $agmsg
```

That's it. Once two agents have joined the same team, they can message each other.

## Install

```bash
./install.sh              # Interactive (asks command name, default: agmsg)
./install.sh --cmd m      # Non-interactive with custom command name
```

The **command name** determines:
- Skill folder: `~/.agents/skills/<cmd>/`
- Claude Code: `/<cmd>`
- Codex: `$<cmd>`

After install, **restart your agent** (Claude Code / Codex) so it picks up the new skill.

## Join a Team

Agents join teams **per-project**. The easiest way:

1. Open Claude Code in your project
2. Run `/<cmd>` (e.g. `/agmsg`)
3. It detects you're not in a team and asks for team name and agent name

Or join manually:

```bash
~/.agents/skills/agmsg/scripts/join.sh myteam alice claude-code /path/to/project
```

To leave a team:

```bash
~/.agents/skills/agmsg/scripts/leave.sh myteam alice
```

## Usage

### Claude Code

```
/agmsg                          — check inbox (all teams)
/agmsg history                  — message history
/agmsg team                     — list team members
/agmsg send <agent> <message>   — send message
```

### Codex

```
$agmsg                          — or /skills → agmsg
```

### Shell (any agent)

```bash
~/.agents/skills/<cmd>/scripts/send.sh <team> <from> <to> "<message>"
~/.agents/skills/<cmd>/scripts/inbox.sh <team> <agent_id>
~/.agents/skills/<cmd>/scripts/history.sh <team> [agent_id] [limit]
~/.agents/skills/<cmd>/scripts/team.sh <team>
~/.agents/skills/<cmd>/scripts/whoami.sh <project_path> <type>
```

## Update

```bash
cd agmsg
git pull
./install.sh --update
```

DB and team configs are preserved. Only scripts and assets are updated.

## Uninstall

```bash
./uninstall.sh              # Interactive (confirms each step)
./uninstall.sh --yes        # Remove everything
./uninstall.sh --keep-data  # Remove skill but keep DB and teams
```

Auto-detects installed skill directories and cleans up: skill files, slash commands, hooks, AGENTS.md sections, and team configs.

## Architecture

```
~/.agents/skills/<cmd>/           # Folder name = command name
├── SKILL.md                      # Skill definition (read by CC & Codex)
├── agents/
│   └── openai.yaml               # Codex metadata
├── scripts/                      # 8 bash scripts
├── templates/                    # Command templates per tool
├── db/messages.db                # SQLite WAL-mode message store
└── teams/                        # Team configs (self-contained)
    └── <team>/
        └── config.json
```

- **Storage**: Single SQLite file with WAL mode
- **Concurrency**: Multiple readers + 1 writer, no conflicts
- **Dependencies**: bash, sqlite3, python3 (formatting only)
- **No daemon**: Direct filesystem access
- **No network**: Everything local

## License

MIT
