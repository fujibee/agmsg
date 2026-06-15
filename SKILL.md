---
name: agmsg
description: Cross-agent messaging via SQLite. Send messages between Claude Code, Codex, Gemini CLI, GitHub Copilot CLI, and other agents. No daemon, no network, no dependencies beyond bash and sqlite3.
---

# Agent Messaging

**IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

## How to use

### Step 0: First-run bootstrap

agmsg keeps its SQLite database, team registry, and runtime state under `~/.agents/skills/agmsg/`. The `./install.sh` install path creates that tree; the Claude Code plugin install path does not (the plugin marketplace flow only drops the skill content into `~/.claude/plugins/cache/`). Before any other command, bootstrap if needed:

```bash
if [ ! -d ~/.agents/skills/agmsg ]; then
  # Locate the plugin install script (any version), run it once.
  installer=$(ls ~/.claude/plugins/cache/fujibee-agmsg/agmsg/*/install.sh 2>/dev/null | head -1)
  if [ -n "$installer" ]; then
    bash "$installer" --cmd agmsg
  else
    echo "agmsg not installed. Either:" >&2
    echo "  - run ./install.sh in the agmsg repo, or" >&2
    echo "  - install via /plugin marketplace add fujibee/agmsg && /plugin install agmsg@fujibee-agmsg" >&2
    exit 1
  fi
fi
```

After this runs once, `~/.agents/skills/agmsg/` is populated and you can skip Step 0 on future invocations.

### Step 1: Check identity

```bash
~/.agents/skills/agmsg/scripts/whoami.sh "$(pwd)" <type>
# type: claude-code, codex, gemini, antigravity, copilot
# Returns: agent=... / multiple=true ... / suggest=true ... / not_joined=true ...
```

### Step 2a: If not in a team — join one

Ask the user for a team name and agent name, then run:

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> <agent_name> <type> "$(pwd)"
```

Do NOT manually edit config files. Always use join.sh.

### Step 2b: If already in a team — execute command

**Default (no arguments): IMMEDIATELY check inbox. Do NOT ask what to do.**

```bash
# Check inbox (marks messages as read) — DEFAULT action
~/.agents/skills/agmsg/scripts/inbox.sh <team> <agent_id>

# Send a message
~/.agents/skills/agmsg/scripts/send.sh <team> <from_agent> <to_agent> "<message>"

# Message history
~/.agents/skills/agmsg/scripts/history.sh <team> [agent_id] [limit]

# List team members
~/.agents/skills/agmsg/scripts/team.sh <team>

# Leave a team
~/.agents/skills/agmsg/scripts/leave.sh <team> <agent_id>

# Rename a team (moves dir, updates config + messages).
# After renaming, each existing member should re-run whoami.sh to refresh
# their cached team name in any running session.
~/.agents/skills/agmsg/scripts/rename-team.sh <old_team> <new_team>

# Show the installed version — the git-describe provenance string recorded at
# install time (tag + commits-since + abbreviated commit, plus -dirty when
# installed from a tree with uncommitted changes). See #117.
~/.agents/skills/agmsg/scripts/version.sh

# Clear registrations for the current project/type.
# A trailing <session_id> additionally releases any actas exclusivity locks
# this session held on <agent_id> so peers can pick them up immediately.
~/.agents/skills/agmsg/scripts/reset.sh "$(pwd)" <type> [agent_id] [session_id]

# Set delivery mode for this project. Replaces the legacy hook.sh on/off,
# which is kept as a deprecated alias only.
#   monitor — real-time push via SessionStart + Monitor tool (claude-code only)
#   turn    — Stop-hook pulls at the end of each assistant turn
#   both    — monitor primary, turn as fallback
#   off     — no automatic delivery
~/.agents/skills/agmsg/scripts/delivery.sh set <mode> <type> "$(pwd)"
~/.agents/skills/agmsg/scripts/delivery.sh status <type> "$(pwd)"

# Multiple roles per project (one CC = one active role).
# Claude Code: `actas` claims an exclusivity lock for <name> across sessions
# and restarts the Monitor filtered to <name> only; peer watchers stop
# subscribing to <name> while this session holds the lock. `drop` releases.
# Codex: actas is send-side only (no stable session_id during slash commands
# → no peer-visible lock). See README "Codex caveat" for details.
~/.agents/skills/agmsg/scripts/actas-claim.sh "$(pwd)" <type> <name> "$session_id"
~/.agents/skills/agmsg/scripts/reset.sh "$(pwd)" <type> <name> "$session_id"

# (Both of the above are normally driven by `/agmsg actas <name>` and
#  `/agmsg drop <name>` slash commands, which also handle the Monitor
#  TaskStop + relaunch dance described in the cmd template.)

# Spawn a NEW agent process that takes an actas identity on boot.
# Pre-joins <name> to a team, then launches the agent CLI in a tmux pane/window
# (when run inside tmux) or a new OS terminal, with `/agmsg actas <name>` as the
# initial prompt. By default it BLOCKS until the new agent's watcher attaches
# (prints `status=ready`), so a leader can send work right after spawn returns
# without losing it to the agent's cold start. claude-code/codex only; macOS
# primary, Linux/Windows best-effort. Non-tmux + no usable terminal (headless)
# errors out.
#   --project <path>     project to launch in (default: $PWD)
#   --team <team>        team to join into (default: auto-resolved from project)
#   --window             new tmux window instead of splitting the current one
#   --split h|v          tmux split direction (default h)
#   --terminal <tmpl>    terminal command template ({cmd} = path to the boot
#                        script) for the non-tmux path; overrides $AGMSG_TERMINAL
#                        / config spawn.terminal. macOS default uses `open -a`
#                        (no Automation/TCC permission prompt).
#   --no-wait            don't block on readiness (fire-and-forget)
#   --ready-timeout N    seconds to wait for readiness (default 90; on timeout
#                        prints status=timeout and exits 3). Codex skips the
#                        wait (it has no Monitor).
~/.agents/skills/agmsg/scripts/spawn.sh <claude-code|codex> <name> [options]
```

## Sandbox compatibility (Claude Code)

When Claude Code's sandbox is enabled, `watch.sh` (monitor mode) runs inside the sandbox and needs to write pidfiles and SQLite WAL files under `~/.agents/skills/agmsg/`. Add an allowlist entry to `~/.claude/settings.json` (or project-level `.claude/settings.local.json`):

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": [
        "~/.agents/skills/agmsg/"
      ]
    }
  }
}
```

The allowlist merges across scopes and takes effect immediately — no restart needed. If agmsg was installed under a custom command name (e.g. `m`), adjust the path accordingly.

**Note on `BASH_SOURCE`**: The sandboxed Bash tool runs commands via pipe/eval, so `BASH_SOURCE[0]` is empty inside sourced functions like `storage.sh`. This is handled internally — `watch.sh` resolves `SKILL_DIR` from `$0` (which works correctly when invoked as a command), and `storage.sh` falls back to that value. No user configuration needed.

## Architecture

- **Storage**: SQLite with WAL mode in `~/.agents/skills/agmsg/db/messages.db`
- **Teams**: `~/.agents/skills/agmsg/teams/<name>/config.json`
- **Concurrency**: WAL allows multiple readers + 1 writer without conflicts
- **No daemon**: Direct DB access via `sqlite3` CLI
- **Dependencies**: bash, sqlite3 (no python3 required)
