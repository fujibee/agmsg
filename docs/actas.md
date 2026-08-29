# `actas` and `drop` — multi-role mechanics

This is the long-form reference for the multi-role workflow introduced briefly in the [README](../README.md#multiple-roles-per-project-actas--drop). Most users will never need this page; reach for it when a lock gets stuck, when an exclusivity decision surprises you, or when you're building tooling on top of agmsg.

## What `actas` does

`actas <name>` is **exclusive across sessions**: it switches both sending and receiving to `<name>` and prevents any other live session from picking up `<name>` until you release it.

Mechanically, the skill:

1. Joins `<name>` under your current team if it isn't registered for this project yet.
2. Claims an exclusivity lock on `(team, name)` under the skill's run directory (`~/.agents/skills/agmsg/run/actas.<team>__<name>.session`).
3. TaskStops the running `agmsg inbox stream` Monitor.
4. Relaunches the Monitor filtered to `<name>` only, via `watch.sh`'s optional 4th argument.

Effects:

- Messages addressed to other roles stop reaching this session.
- Other live sessions stop subscribing to `<name>` — their watchers exclude any pair locked by a peer at startup.
- If another session already holds the lock, `actas` refuses with a clear error. Drop it from that session first.

The lock is released by `drop`, by session end, or by garbage collection when the holding session is no longer alive.

## What `drop` does

`drop <name>` removes only that role's registration for this project (via `reset.sh`). If the role is no longer registered anywhere, it's also dropped from the team config.

If `<name>` was the currently-active role, the watcher is restarted in default mode — no `actas` name filter, so it receives every `(team, agent)` pair registered for this project that isn't held by another session.

## Session scope

Switching is session-scoped state held by the agent. `/clear` or a new session resets back to the multiple-identities picker.

## Recovery from a stuck lock

`actas-claim.sh` writes the lock file before the skill TaskStops the old Monitor and launches the new one. If that subsequent dance fails — TaskStop succeeds but the new Monitor invocation errors out — the lock stays put but the session has no narrowed watcher.

To unstick:

- Run `/agmsg drop <name>` in this session, or
- End the session.

Either releases the lock so peers can pick it up.

## Liveness and PID recycling

A stale lock is reclaimed when its owner session_id no longer maps to any live cc-instance, where "live" is checked via `kill -0`.

PID recycling could in theory keep a long-dead session looking alive forever, starving peers from claiming or reaching its name. This is tracked in [#67](https://github.com/fujibee/agmsg/issues/67) and not addressed in v1.

## Subscription model

agmsg follows a **one CC session = one active role** model. Each watcher subscribes to a *static* set of identities decided at launch:

- **Without `actas`**: the watcher subscribes to whichever `(team, agent)` pairs were registered for this `(project, agent_type)` at the moment `watch.sh` started, *minus* any pair currently locked by another live session's `actas` claim. The set is *not* re-resolved later — a peer that claims a name after this watcher launched will start receiving exclusively, but this watcher won't notice the loss until it restarts. A role joined mid-session via `actas` from another CC does *not* start arriving in CCs that were launched before it.
- **After `actas <name>`**: the watcher is relaunched filtered to `<name>` only, and the lock that filter implies prevents peer watchers from ever subscribing to `<name>` while this session is live.

This is intentional. It keeps each CC bound to one role's inbox, so a `tech-lead` window stays clear of `biz-analyst` traffic and vice versa, and the exclusivity holds across sessions on the same machine rather than per-session.

To pick up a role added after a CC launched (without switching to it exclusively), restart the CC or `/clear` so SessionStart re-launches `watch.sh` with the fresh identity list — and with the up-to-date lock view.

The send side mirrors this: every `send.sh` call from this CC uses the active role as the `from` agent, whether that's the implicit one (default) or the one set by the most recent `actas`.

## Codex caveat

On Codex, `$agmsg actas <name>` is **send-side only** for this session. Codex slash commands don't see a stable `session_id`, so they can't claim a peer-visible exclusivity lock — Claude Code peers will still subscribe to `<name>`.

The receive side isn't actually narrowed either: `check-inbox.sh` resolves identity through `whoami.sh` (which picks the first registered agent) and has no view of the agent's in-session actas role, so Codex keeps polling whichever pair it would have without actas. The check-inbox lock filter only skips pairs *another* session owns.

Treat Codex actas as a from-line override until a Codex session-id story exists. Claude Code's `/agmsg actas` does claim the lock symmetrically and is the path that exercises the full exclusivity model.

<!-- Observation draft for #798: a docs-only diff, opened to read the shard check names on a real docs-only run. Close without merging. -->
