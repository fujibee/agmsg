# ADR 0005: Codex invocation-scoped app-server lifecycle

**Status:** proposed
**Date:** 2026-08-30
**Deciders:** @fujibee

## Context

The Codex monitor normally reuses one app-server per project and replaces itself
with the TUI. Remote tool processes can therefore keep a disposable worktree as
their working directory after that TUI closes. A project hash, process name, or
Codex thread ID cannot prove which OS processes belong to one invocation when
several sessions share the server. This is the narrow managed-worktree case in
[#149](https://github.com/fujibee/agmsg/issues/149).

## Decision

Add opt-in `codex-monitor.sh --invocation-scope <token>` mode. The monitor
validates the token, hashes it with the canonical project path, acquires a lease
for that key, and starts a fresh app-server. It supervises the TUI, app-server,
and top-level bridge launcher as captured shell jobs. Normal TUI exit stops and
waits for the captured server and launcher, removes only matching records and
the keyed request, releases the lease, and returns the TUI status. Direct
`TERM` also reaps the captured TUI and returns 143.

The raw token is never used as a path. `AGMSG_CODEX_APP_SERVER_KEY` contains
only the derived 40-character hexadecimal key. Scope-less launches scrub that
key and any inherited bridge URL before deriving their project-shared records.
Malformed inherited keys fail closed before any request path or lock resource
is used.

Scoped SessionStart requests and dispatcher locks use the same app-server key.
The monitor clears a pre-existing keyed request immediately after acquiring the
lease and again during cleanup, so an old request cannot route a new invocation.
A scoped launcher accepts only a three-field request whose thread is nonempty
and whose app-server URL equals the URL captured at launch. Missing, malformed,
or mismatched requests leave messages unread.

Each scoped dispatcher selects only roles whose canonical project and recorded
thread match its request. The existing project-and-role child lock remains
global, so one role still has at most one bridge consumer across scopes. A
scoped child proves the project-and-thread match before acquiring that lock. If
the role seat moves, the old child uses the existing bridge lease and process
start-token checks to retire its exact bridge, then releases the lock for the
new matching scope. Bare bridge pidfiles are not signal authority.

Scope-less launches retain project server reuse, the project dispatcher key,
and TUI `exec` behavior.

## Alternatives considered

- Treat every child of a shared server as owned by the closing TUI. Rejected:
  the server can host work from another session.
- Use only Codex thread IDs. Rejected: they do not enumerate the OS process
  tree or establish signal authority.
- Add a daemon, reference counter, or durable scope field to role records.
  Rejected: keyed requests, dispatchers, and the existing global role lock are
  sufficient.
- Make every launch scoped. Rejected: existing users may depend on project-wide
  reuse and its lower startup cost.

## Consequences

- Positive: disposable-worktree callers get a bounded, opt-in app-server
  lifecycle without signaling foreign sessions.
- Positive: concurrent scopes route distinct role threads to their exact
  servers while preserving one consumer per project role.
- Positive: no dependency, daemon, schema change, or second bridge cleanup
  mechanism is introduced.
- Negative: every scoped invocation pays fresh app-server startup cost.
- Negative: `SIGKILL` cannot run traps and may leave a server, request, or lease.
  Readiness must fail closed and recovery remains an explicit incident action.
- Neutral: the supervisor's signal authority is its captured shell jobs;
  bridge replacement separately uses the existing lease and start-token proof.

## References

- [Issue #149](https://github.com/fujibee/agmsg/issues/149)
- `scripts/drivers/types/codex/codex-monitor.sh`
- `scripts/drivers/types/codex/codex-bridge-launcher.sh`
- `docs/codex-monitor-beta.md`
