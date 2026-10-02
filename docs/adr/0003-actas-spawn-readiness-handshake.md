# ADR 0003: Opt-in actas-completion handshake for spawned agents

**Status:** proposed
**Date:** 2026-07-19
**Deciders:** @fujibee

## Context

`agmsg spawn` can hand work to a new agent immediately after launch. For a
driver with a SessionStart-launched watcher, spawn can wait for the existing
long-lived `ready.<team>__<agent>` sentinel before returning. Some drivers do
not have that lifecycle hook. Grok Build, for example, starts its watcher only
when the model follows the `actas` instructions, and turn/off delivery modes do
not start a watcher at all.

Treating watcher readiness as universal caused turn/off Grok spawns to wait for
a signal that could never arrive. Disabling the wait fixed the hang, but brought
back the cold-start race: the parent could send a task before the spawned model
had claimed its identity and processed the first turn. Issue #338 documents
first-turn startup times of 143–187 seconds, so the existing 90-second default
is also too short for an explicit model-driven handshake.

The agent-type manifest needs a way to declare that its own `actas` flow has a
reliable, explicit completion point without changing any driver that does not
opt in.

## Decision

Add the optional agent-type manifest key `handshake=actas`. A driver declaring
it must call `ready.sh mark <team> <agent> [nonce]` exactly once after identity
claim and any required delivery setup complete. `spawn.sh` clears that driver's
stale one-shot sentinel before launch, waits for it, consumes it after
observation, and enforces a minimum timeout of 300 seconds. `--no-wait` remains
an explicit opt-out.

Each `spawn` invocation with `handshake=actas` generates a per-launch nonce and
exports it (with the resolved team) as `AGMSG_SPAWN_TEAM`/`AGMSG_SPAWN_NONCE`
for the template to echo back on mark, and requires the check to see that exact
nonce. Without this, a mark from an abandoned or timed-out earlier launch for
the same (team, agent) — still possible after its own 300s wait gives up,
since the model may keep booting past that point — could satisfy a *later*
spawn's check, reporting `status=ready` before that later launch's own agent
has actually completed bootstrap (review finding, 2026-07-19).

The one-shot file is named `actas-ready.<team>__<agent>` (with the existing
lossless filesystem encoding). It is separate from the watcher-owned
`ready.<team>__<agent>` sentinel: the former records one bootstrap edge and is
consumed, while the latter represents live watcher state and remains present
for the watcher lifetime.

Types without `handshake=actas` retain their current behavior. In particular,
`monitor=yes` types continue using watcher readiness, while `monitor=no` types
continue returning immediately.

## Alternatives considered

- **Wait unconditionally for every spawn.** Rejected because drivers without a
  watcher or explicit first-turn callback have nothing that can signal; this
  recreates the turn/off timeout hang.
- **Make waiting the default and add per-driver opt-outs.** Rejected because a
  new default changes every existing and third-party driver. An opt-in key is
  backward-compatible and makes the driver author responsible for a real mark
  point.
- **Condition waiting on delivery mode.** Rejected because delivery mode is not
  bootstrap completion. Turn/off agents still need identity claim before work
  can be addressed to them, and a monitor rule merely promises the model will
  start a watcher; it does not prove that it has done so.
- **Reuse the watcher `ready.*` sentinel.** Rejected because that file encodes
  ongoing watcher liveness and is removed on watcher exit. Treating an
  actas-completion edge as liveness would leave ambiguous ownership and stale
  state, especially in turn/off modes where no watcher exists.
- **Keep Grok Build fire-and-forget only.** Rejected because it avoids hangs but
  preserves the cold-start message race reported in #338.

## Consequences

- Positive: opt-in drivers can provide a deterministic handoff point even
  without SessionStart hooks or a monitor watcher.
- Positive: existing and external drivers without the key do not change.
- Positive: watcher liveness and one-shot bootstrap completion remain distinct
  protocols with distinct filenames and lifetimes.
- Negative: an actas-capable template must faithfully call `ready.sh mark`; if
  the model does not follow the instruction, spawn waits until the 300-second
  floor expires.
- Negative: the handshake is model-driven, so it cannot be as early or as
  deterministic as a native lifecycle hook.
- Neutral: callers that prefer fire-and-forget retain `--no-wait`.

## References

- [fujibee/agmsg issue #338](https://github.com/fujibee/agmsg/issues/338), Gap 2
- Gap 2 design and incident evidence contributed by @Salmonellasarduri
- Existing watcher readiness handshake: issue #108
