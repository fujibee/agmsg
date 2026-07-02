# agmsg — Design & Architecture

*[日本語](design.ja.md)*

Developer documentation for contributors and maintainers.

## Identity Model

An agent is identified by `(name, team)`. Project path and agent type (claude-code, codex, gemini) are metadata — reference information stored alongside the identity but not part of it.

- An agent can be registered from multiple projects under the same name
- `whoami.sh` uses project path and type to suggest an identity, but the user can choose any name
- See [#15](https://github.com/fujibee/agmsg/issues/15) for the ongoing identity redesign

## Data Storage

### Messages — SQLite

`~/.agents/skills/<cmd>/db/messages.db`

- Path resolved by `scripts/lib/storage.sh` (`agmsg_db_path`); override the storage directory with `AGMSG_STORAGE_PATH` (env > built-in default). Scoped to the SQLite store only.
- WAL journal mode for concurrent access (multiple readers + 1 writer)
- Schema:
  ```sql
  CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    team TEXT NOT NULL,
    from_agent TEXT NOT NULL,
    to_agent TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    read_at TEXT
  );
  ```
- Indexes on `(team, to_agent, read_at)` for unread queries and `(team, created_at)` for history

### Team Config — JSON

`~/.agents/skills/<cmd>/teams/<team>/config.json`

```json
{
  "name": "myteam",
  "agents": {
    "alice": { "type": "claude-code", "project": "/path/to/project" }
  },
  "created_at": "2026-01-01T00:00:00Z"
}
```

Manipulated via sqlite3 JSON1 functions (no python3 dependency).

### User Config — YAML

`~/.agents/skills/<cmd>/db/config.yaml`

```yaml
# agmsg configuration
hook:
  check_interval: 60  # seconds between inbox checks
```

Read/written by `config.sh` using awk. Supports dotted keys (`hook.check_interval`).

## Hook System

Auto message detection uses the host agent's hook mechanism to check for new messages after each response.

### Flow

```
Agent responds → Stop hook fires → check-inbox.sh runs
  ├─ Cooldown active? → skip (Codex: JSON systemMessage)
  ├─ No unread messages? → silent (Codex: JSON systemMessage)
  └─ Unread messages found:
       1. Build notification text
       2. Mark messages as read_at
       3. Return JSON { "decision": "block", "reason": "..." }
       4. Agent sees messages in context and continues
```

### Cooldown

A marker file (`run/.lastcheck-<agent>`) tracks the last check time. Configurable via `hook.check_interval` (default 60 seconds). It lives in the run dir (hook runtime state), not the message store, so it is unaffected by `AGMSG_STORAGE_PATH`.

### Claude Code vs Codex

| Aspect | Claude Code | Codex |
|---|---|---|
| Hook config | `.claude/settings.local.json` | `.codex/hooks.json` |
| Feature flag | Not needed | `codex_hooks = true` in `config.toml` |
| Silent output | exit 0 with no output | JSON `{ "continue": true }` |
| New messages | `decision: "block"` | `decision: "block"` |
| UI label | "Stop hook error:" ([#2](https://github.com/fujibee/agmsg/issues/2)) | "warning:" ([#2](https://github.com/fujibee/agmsg/issues/2)) |

### Project resolution ([#92](https://github.com/fujibee/agmsg/issues/92))

Slash commands pass `"$(pwd)"` as the project key. When the user `cd`s into a
subdirectory or git worktree of the project the session actually lives in, that
pwd no longer matches the registered project — lookups miss and a phantom record
gets minted for the subdir. `lib/resolve-project.sh` recovers the real root with
three signals, none needing a stable `session_id` (Codex doesn't expose one):

1. **Per-process marker.** At SessionStart, `proj.<agent_pid>.project` records
   the authoritative project (the hook's baked-in `$2`), keyed by the enclosing
   agent process PID. A slash command runs as a child of that same process, so
   it walks the ppid chain to the agent PID and reads the marker back. Trust is
   gated on the PID still being a live agent process (recycling guard); stale
   markers are GC'd at SessionStart/SessionEnd. **Claude Code monitor/both
   only** — Codex rejects monitor mode (no Monitor tool), so it never installs
   `session-start.sh` and writes no marker; Codex relies on signals 2–3.
2. **Ancestor walk.** Failing a marker, the nearest ancestor of pwd that is a
   registered project for the type wins. Git-independent — covers nested
   subdirs and worktrees that live *under* the registered project, on cc and
   Codex alike.
3. **Git common-dir.** Failing that, the registered main checkout of pwd's git
   repo (via `git rev-parse --git-common-dir`), recovering a *sibling* worktree
   the ancestor walk cannot reach. Validated against the registry, so it
   declines when registration sits on an umbrella parent dir.

Order: marker → ancestor → git-common-dir → pwd (unchanged fallback).
Resolution is applied by the agent-driven entry points (`whoami.sh`,
`actas-claim.sh`, `join.sh`, `reset.sh`, and `watch.sh` — whose subscription
must track the same resolved project); direct shell invocations and
`spawn.sh`'s explicit `--project` opt out via `AGMSG_RESOLVE_PROJECT=0`.
`identities.sh` stays a pure lookup — its callers pass an already-resolved path.

## Scripts

| Script | Purpose |
|---|---|
| `internal/init-db.sh` | Create SQLite database with schema |
| `send.sh` | Insert a message into the database |
| `inbox.sh` | Show unread messages and mark as read |
| `history.sh` | Show message history (newest first, displayed oldest first) |
| `join.sh` | Add agent to team (create team if needed) |
| `leave.sh` | Remove agent from team (delete team if empty) |
| `team.sh` | List team members |
| `whoami.sh` | Identify agent by project path and type |
| `rename.sh` | Rename agent in config and message history |
| `check-inbox.sh` | Hook entry point — cooldown, check, notify |
| `config.sh` | Read/write user config (YAML) |

All scripts use only `bash` and `sqlite3`. No python3 dependency.

## Install Layout

```
~/.agents/skills/<cmd>/
├── SKILL.md              # Read by Codex (generated from cmd.codex.md template)
├── agents/
│   └── openai.yaml       # Codex metadata
├── scripts/              # All shell scripts
├── templates/            # Command templates (cmd.claude-code.md, cmd.codex.md)
├── db/
│   ├── messages.db       # SQLite message store (relocatable via AGMSG_STORAGE_PATH)
│   └── config.yaml       # User configuration
├── run/                  # Hook/watcher runtime state
│   ├── watch.<sid>.pid   # Monitor watcher pidfiles
│   ├── proj.<pid>.project # Session's real project root, keyed by agent PID (#92)
│   └── .lastcheck-*      # Cooldown markers
└── teams/
    └── <team>/
        └── config.json   # Team member registry
```

Claude Code command is installed separately to `~/.claude/commands/<cmd>.md`.

## Dependencies

- **bash** — shell
- **sqlite3** — database and JSON manipulation (JSON1 extension)
- **awk/sed** — text processing (config, TOML editing)

No python3, no node, no network, no daemon.
