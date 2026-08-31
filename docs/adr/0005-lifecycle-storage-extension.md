# ADR 0005: Lifecycle storage extension and whole-store export

**Status:** proposed
**Date:** 2026-09-01
**Deciders:** @fujibee

## Context

The message-store contract provides durable messages and recipient-scoped read
state, but it does not provide a stable operation identity, application-level
acknowledgements, notifier retry state, or a public work-history query. Callers
that need those guarantees would otherwise have to infer completion from
delivery hooks, inspect SQLite tables directly, or create another durable
ledger. Each choice splits lifecycle truth from the message store and leaves a
crash window between the message and its receipt or wake state.

The bundled SQLite export already treats its selected physical database as a
whole-store backup/convert source for legacy message events. Adding team-filtered
lifecycle records to that stream would produce an internally incomplete backup:
legacy events for every team would survive conversion while lifecycle state for
all but one team would disappear.

## Decision

Add an optional, explicitly reported `lifecycle-v1` extension to the existing
storage facade. The extension owns operation-key idempotency, delivery and read
receipts, processing-lease renewal, application ACKs, work registration/events,
durable wake/cleanup/launch outboxes, and lifecycle history/active queries.
SQLite implements the complete capability. Drivers that do not implement it
report each capability as `unsupported` and fail lifecycle calls visibly; core
does not substitute a private adapter, delivery hook, or second store.

Keep lifecycle state in additive tables within the same SQLite database and
transaction domain as the message log. A logical send commits its message,
delivery receipt, and wake outbox atomically. ACK and cleanup, work registration
and launch, and outbox ownership transitions use the same rule. Processing
leases are renewable only by their current consumer while unexpired.
Registration is the only way to create a `registered` work event and its launch
outbox. Later work events carry the current registration generation; stale
generations fail rather than being projected onto newer work. Terminal work
states seal their generation and cannot be reopened by a delayed transition.
Public history
includes current processing leases and outbox rows, including ownership,
expiry, attempt, and error state, so recovery does not require private-table
access.

Define SQLite `storage_export` as a whole-store backup/convert operation. It
exports legacy v1 events and lifecycle messages, events, outboxes, and processing
leases for every team in the physical store. Import validates known lifecycle
records and applies the complete input atomically. Exact duplicates are
idempotent; semantic, identity, or graph-reference conflicts fail instead of
being ignored. Graph references are checked after the complete input has been
staged, so record order cannot bypass receipt, ACK, outbox, or control-event
invariants. Validation is symmetric: atomic send, ACK/cleanup, and
registration/launch pairs cannot lose either side. Control events agree with a
reachable outbox state, and processing leases agree with ACK absence and their
read-receipt attempt history. Processing leases and ACKs belong to the latest
matching read-receipt owner, with ACK causally after that receipt. Historical
retry/sent events remain valid after later transitions, while current outbox
status and attempts must be writer-
reachable. Completed wakes are backed by reads; completed cleanup/launch rows
are backed by sent events, outbox attempts cover completed controls plus any
in-flight lease, and launch metadata matches registration both ways.
Cross-record references do not depend on JSONL
record-type order. Exact replay also leaves the legacy message projection unchanged.
Every record shape produced by the SQLite writer is valid input
to the same version's importer, including multiline diagnostic text.

## Alternatives considered

- **Keep lifecycle state in a second durable ledger.** Rejected because message
  delivery and lifecycle transitions would no longer share one transaction or
  one backup/restore boundary.
- **Let unsupported drivers emulate lifecycle through hooks or private tables.**
  Rejected because capability probes would claim readiness without the required
  durability, query, and crash-recovery semantics.
- **Export lifecycle records only for the selector-named team.** Rejected because
  SQLite already exports legacy events for the whole physical store, so the
  resulting backup would silently drop part of other teams' state.
- **Make the complete lifecycle surface mandatory for every storage driver.**
  Rejected for this revision. Explicit unsupported reporting preserves legacy
  drivers without weakening the activation probe.

## Consequences

- Positive: messages, receipts, leases, ACKs, and notifier retries share one
  transaction, migration, query, and backup boundary.
- Positive: callers can gate activation on an explicit capability document and
  never need to inspect a private SQLite schema.
- Positive: SQLite backup/convert round-trips every team's lifecycle graph.
- Negative: lifecycle-v1 increases the optional storage ABI and requires each
  driver to report unsupported operations explicitly until it implements them.
- Negative: the migration is additive only. Rolling back the executable leaves
  lifecycle tables intact; an older executable ignores them but cannot continue
  lifecycle processing.
- Neutral: this ADR does not activate lifecycle adapters in `.agents`, remove an
  older runtime, change global agent instructions, or authorize another durable
  store.

## References

- [Driver interface specification](../spec/driver-interface.md)
- [ADR 0003: Storage axis](0003-storage-axis-driver-abi-and-scope.md)
- [fujibee/agmsg issue #373](https://github.com/fujibee/agmsg/issues/373)
- [cattyneo/.agents issue #277](https://github.com/cattyneo/.agents/issues/277)
