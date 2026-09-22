# ADR 0005: ext-tool adapters may ship an opt-in companion watcher

**Status:** proposed
**Date:** 2026-09-22
**Deciders:** @fujibee

## Context

`scripts/drivers/ext-tools/README.md` states that no ext-tool adapter runs
as a standing process: `handle` starts, does its one job, and exits, and
delivery to an ext-tool member happens only through a `send`/`sync` this
machine already made.

That contract fits request/response tools (Slack's API, a decision
endpoint). It does not fit tools whose only interface is a *human-facing UI
with no inbound channel*. The motivating case is the `chatgpt` driver
(#1382): the member is a ChatGPT conversation living in a browser tab.
There is no webhook, no socket, nothing that calls us — the only way to
learn that ChatGPT answered, or that a human typed into the same tab, is to
poll the page.

Without a watcher the driver still works for `mode=sync-wait` (handle waits
for the reply inline). But two real behaviours are impossible without one:

- `mode=inject-only`: handle enqueues and returns immediately, so nothing
  is around to notice the reply and relay it back into the team.
- `human_relay_to`: text a human types straight into the tab is invisible
  to agmsg unless somebody is looking at the transcript.

## Decision

An ext-tool adapter may ship an optional companion watcher process under
these conditions:

- It is strictly opt-in: nothing runs unless the member config or the
  delivery path asks for it (for `chatgpt`: `mode=inject-only` or
  `human_relay_to`, and `watch=no` opts back out).
- It is spawned lazily by `handle` and self-heals the same way (a singleton
  lock whose owner pid is re-checked on every delivery); no external
  supervisor is required.
- It is one process per member config, terminates on SIGTERM, and keeps no
  state outside the member's own config-adjacent files.
- Replies it relays are posted through `send.sh` under the member's own
  name; it never consumes another member's inbox cursor.

The `sync-wait` path remains exactly the standing contract: `handle` alone,
one job, exit.

## Alternatives considered

- **Keep the spec absolute; sync-wait only.** Rejected: it silently loses
  every reply sent to an inject-only member and makes human-in-the-loop
  tabs unreachable, which were the motivating use cases. A spec-conformant
  subset would ship a driver that looks supported but drops real traffic.
- **Fold the watch into `handle` by keeping it alive.** Rejected: the
  dispatcher enforces `tool.conf`'s `timeout` by killing the process group;
  a long-lived handle is killed exactly when it becomes useful.
- **Require an external supervisor (launchd/systemd).** Rejected: it adds a
  per-machine provisioning step for an optional feature, and duplicates the
  lifecycle knowledge the adapter already has.

## Consequences

- Positive: browser-tab and similar UI-bound tools can participate
  bidirectionally without a dedicated agent seat; the opt-in boundary keeps
  the standing-process exception narrow and auditable.
- Negative: the "no standing process" invariant is no longer absolute, so
  `doctor.sh`-style health reporting must know where to look (the `chatgpt`
  driver's `setup status` reports watcher liveness and queue depth for
  this).
- Neutral: the dependency surface grows by the host environment the watcher
  polls (for `chatgpt`, the `orca` CLI); a machine without it sees the same
  clean failure path as any absent optional tool.

## References

- Issue: https://github.com/fujibee/agmsg/issues/1382
- `scripts/drivers/ext-tools/README.md` ("no ext-tool adapter runs as a
  standing process" — the contract this ADR amends)
