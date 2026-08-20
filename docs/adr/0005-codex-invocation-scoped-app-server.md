# ADR 0005: Codex invocation-scoped app-server lifecycle

**Status:** proposed
**Date:** 2026-08-21
**Deciders:** @fujibee

## Context

The Codex monitor currently reuses one app-server per project, launches its
bridge dispatcher in the background, and then replaces the monitor with the
Codex TUI via `exec`.  Remote tool processes inherit the TUI thread working
directory from that shared app-server, so closing one TUI does not provide an
ownership boundary for its workers.  The orphan behavior is tracked in
[#149](https://github.com/fujibee/agmsg/issues/149).

Some callers launch Codex in a disposable Git worktree and must prove that all
remote processes using that worktree have ended before removing it.  A project
hash, process name, shared parent PID, or logical Codex thread ID cannot prove
OS-process ownership when several sessions share one app-server.

## Decision

Add an opt-in `codex-monitor.sh --invocation-scope <token>` mode.  The token is
validated, combined with the canonical project path, and hashed before it is
used as the app-server record key.  A scoped launch never reuses an existing
app-server: the monitor acquires an exact scope lease, starts a fresh app-server
as its child, runs the Codex TUI as a supervised foreground child, and on TUI
exit stops and reaps its captured server, launcher, and TUI launch tree before
returning the TUI status.  A direct `TERM` takes the same path and returns
status 143.  A live duplicate scope fails closed.  Scope-less launches retain
the existing project-shared app-server and `exec` behavior.

Only app-server lifetime is invocation-scoped.  agmsg role seating, the bridge
request, and dispatcher ownership remain project-scoped so concurrent sessions
cannot create duplicate inbox consumers.  The scoped server key is inherited
internally as `AGMSG_CODEX_APP_SERVER_KEY`, allowing hook-side code running in
the app-server context to resolve the correct port without exposing the raw
token or falling back to another invocation's project server.

## Alternatives considered

- **Classify every shared app-server child as owned.** Rejected because a shared
  server can have same-cwd workers from another Codex session.
- **Bind cleanup only to Codex thread IDs.** Rejected because thread APIs do not
  enumerate every OS worker or provide a complete PID ownership tree.
- **Disable agmsg monitor for disposable worktrees.** Safe, but removes real-time
  delivery from the exact sessions that use multi-agent work most heavily.
- **Make every bridge and role record invocation-scoped.** Rejected because it
  would create competing consumers for one project role and is unnecessary for
  process ownership.
- **Change all monitor launches to scoped lifetime.** Rejected for compatibility;
  current users may rely on project-wide server reuse.

## Consequences

- Positive: a scoped monitor has one exact server process tree that can be
  drained without inspecting or signalling foreign project sessions.
- Positive: fresh and resume launches use the same lifecycle contract, preserve
  the Codex exit status, and leave the existing no-scope behavior unchanged.
- Positive: no daemon, external dependency, or second cleanup implementation is
  introduced.
- Negative: scoped launches pay app-server startup cost on every invocation.
- Negative: the monitor does not prove that every detached remote or role
  descendant has independently exited.  They naturally bind to the scoped
  app-server lifetime, while the final caller still decides readiness.
- Negative: `SIGKILL` can leave a stale lease; the next same-scope launch fails
  closed unless it can prove the recorded owner is dead before reclaiming it.
- Neutral: project role seating remains single-owner/latest-seat behavior.

## References

- [Issue #149](https://github.com/fujibee/agmsg/issues/149)
- `scripts/drivers/types/codex/codex-monitor.sh`
- `scripts/drivers/types/codex/codex-bridge-launcher.sh`
- `docs/codex-monitor-beta.md`
