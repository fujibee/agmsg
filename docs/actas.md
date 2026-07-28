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

If checked lock cleanup cannot run (for example, reclaim SQLite is unavailable
or a legacy `.reclaim.d` marker remains), `drop` exits nonzero. In the normal
checked-cleanup failure path, it restores the prior registration while retaining
the lock so retry is safe after recovery; the diagnostic includes
`retained=<team>/<name>` (or a comma-separated exact set). If that restoration
write also fails, the command still exits nonzero and reports the retained pair,
but inspect the team registry before retrying. Do not treat either outcome as a
successful drop or remove the lock by hand—restore the reported infrastructure
first.

## Session scope

Switching is session-scoped state held by the agent. `/clear` or a new session resets back to the multiple-identities picker.

## Recovery from a stuck lock

`actas-claim.sh` writes the lock file before the skill TaskStops the old Monitor and launches the new one. If that subsequent dance fails — TaskStop succeeds but the new Monitor invocation errors out — the lock stays put but the session has no narrowed watcher.

To unstick:

- Run `/agmsg drop <name>` in this session, or
- End the session.

Either releases the lock so peers can pick it up.

### Protocol upgrade and rollback boundary

The current SQLite reclaim mutex and the older `.reclaim.d` mutator are not a
mixed-version protocol. Before the first new-protocol mutation, stop every old
agmsg agent, watcher, hook, and in-flight lock helper; upgrade every such
process consistently; then restart them on the new version. Do not run old and
new mutators together.

Before rolling back code, first quiesce every new-protocol helper and process.
Retain and inspect `run/actas-reclaim.db`; do not delete it to force a rollback
or infer that its rows are stale from their age. Only after the helpers are
known to have stopped should all processes move back to the older version.

Legacy marker detection is diagnostic and fail-closed, not proof that the
system is quiescent: an old mutator can begin after a new helper's final marker
check. The absence of a marker likewise does not authorize a mixed-version
operation.

### Legacy `.reclaim.d` transition

Older agmsg versions serialized stale-lock removal with an empty directory next
to the lock, named `actas.<team>__<name>.session.reclaim.d`. An empty directory
cannot reveal whether its old owner crashed or is merely paused, so the current
version deliberately fails closed when one exists. SessionStart prints each
affected path and never deletes it automatically.

To recover safely:

1. Stop every agent, watcher, hook, or other agmsg process that could still be
   running the old lock mutator, then restart them on the upgraded version.
2. Inspect the exact paths reported by SessionStart. Confirm each is the
   affected empty `.reclaim.d` directory and that no old mutator remains able to
   enter it.
3. Remove only those confirmed empty directories. Do not recursively remove
   the surrounding lock or run directory.
4. Retry `actas` or restart the affected session.

Never infer safety from a marker's age and never run age-based cleanup. A live
old mutator may remain paused for an arbitrary amount of time.

### Incomplete multi-team rollback

A name may be registered in more than one team, so `actas-claim.sh` can claim
one pair before a later pair encounters a filesystem or SQLite failure. Group
claim and rollback are not atomic. The script aborts before changing the
Monitor or recording role affinity and attempts a mutex-protected rollback. If
that same infrastructure prevents cleanup, the error includes
`rollback=incomplete locked=<pairs>` with the exact retained pairs.

Do not delete those lock files directly. Restore the reported infrastructure
and retry so checked cleanup can finish. Until infrastructure recovers—or a
future #519 generation-bearing record protocol provides stronger fencing—the
safe behavior is to diagnose and retain those locks, not claim rollback
completed.

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
