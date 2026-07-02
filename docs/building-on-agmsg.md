# Building on agmsg

This is for anyone writing a program *outside* agmsg's own bash scripts that
wants to read or act on agmsg data — a GUI app, a web dashboard, a bot in
another language, a derivative project (`agmsg-shogi`, `agmsg-go`,
`agmsg-mcp`, …). If you're extending agmsg's own behavior (a new agent type,
a new storage backend), see [Plugins](plugins.md) instead — this doc is about
consuming agmsg from the outside, not swapping a piece of it from the inside.

## The rule: go through scripts, not files

agmsg's actual storage (a SQLite file today, `teams/<team>/config.json` for
rosters) is an implementation detail, not a contract. Design work is underway
for a pluggable storage axis — swappable backends behind a common contract,
so a message store doesn't have to be this SQLite file. Code outside
`scripts/` that opens `messages.db` directly, or hand-parses a team's
`config.json`, will break with no warning if that lands. Go through the
scripts in `scripts/` instead — they're the stable surface; what's behind
them is free to change.

## Reading data: `scripts/api.sh`

```sh
~/.agents/skills/<cmd>/scripts/api.sh get teams
~/.agents/skills/<cmd>/scripts/api.sh get teams <team> members
~/.agents/skills/<cmd>/scripts/api.sh get teams <team> messages [--agent <name>] [--limit N] [--before-id <id>]
```

JSON out — plain lines for `teams`, JSONL (one record per line) for
`members`/`messages`. `messages` returns oldest-first, capped by `--limit`
(default 30, meaning the most recent 30 — not the first 30), each record
shaped like:

```json
{"type":"message_sent","id":1234,"team":"agsuite","from":"alice","to":"bob","body":"...","at":"2026-07-02T10:00:00Z"}
```

That shape isn't incidental — it matches the `message_sent` event shape the
in-progress storage-axis design defines for a future `storage_history`
primitive. `api.sh` queries sqlite directly today; once that axis lands, this
command is meant to become a thin call into the driver-agnostic function
instead, with **no change to this output**. Code that consumes `api.sh`'s
JSON today keeps working unmodified after that migration — which is the
whole point of going through it instead of the database file.

`api.sh` is intentionally read-only in v1 and shaped like a small REST API —
verb (`get`) + resource nouns (`teams`, `members`, `messages`) — kubectl-style
positional args rather than a `/teams/<team>/messages`-style path string
(there's a fixed, small set of routes; a path string would just add parsing
overhead on both ends for no real flexibility). A write verb (`post` for
send, say) is a plausible future addition — the shape is deliberately left
room to grow into that without a redesign.

## Writing data: the existing write scripts

There's no write API yet — call the same scripts agmsg's own CLI-driven
flows use:

| Action | Script |
|---|---|
| Send a message | `scripts/send.sh <team> <from> <to> <body>` |
| Join a team / register an agent | `scripts/join.sh <team> <name> <type> <project>` |
| Rename an agent | `scripts/rename.sh <team> <old> <new>` |
| Remove an agent from a team | `scripts/leave.sh <team> <name>` |
| Check delivery mode | `scripts/delivery.sh status [<type> <project>]` |
| Set delivery mode | `scripts/delivery.sh set <mode> <type> <project>` |

These are the same scripts `/agmsg` (or your configured command) itself
shells out to — there is no more-privileged internal path. Treat them as the
only sanctioned way to mutate agmsg state; nothing outside `scripts/` should
write to `db/` or `teams/` directly, for the same forward-compatibility
reason reads go through `api.sh`.

## Spawning and driving an agent

Reading/writing agmsg data is one half of "building on agmsg" — the other is
actually running an agent under it, e.g. a GUI that opens a real terminal and
boots a CLI agent into a team. That's not a script call: give the agent's CLI
`/<cmd> actas <name>` as its initial prompt (mirroring what `spawn.sh` does
for a CLI-driven spawn) against a PTY or terminal you own, and — for a type
whose CLI doesn't self-deliver — write inbound messages straight into that
PTY's stdin yourself as they arrive, rather than waiting for the CLI to look
idle (idle-detection heuristics are fragile — some CLIs keep redrawing a
spinner well after they're actually ready for input). A short pause between
the message text and the Enter keystroke is worth building in too: some CLIs
misread text+Enter written back-to-back as a paste and swallow the Enter.

## Versioning and stability

`api.sh`'s interface (verbs, resource nouns, the JSONL record shape) is meant
to stay stable across releases the way the write scripts' argument order
already does. A breaking change to it would be called out in
[CHANGELOG.md](../CHANGELOG.md) same as any other breaking change. There is
no version negotiation yet (no `api.sh version`, no content-type header) —
if your project needs to pin against a specific agmsg version, pin the
install (see [Update](../README.md#update)) rather than assuming forward
compatibility of anything not documented here.
