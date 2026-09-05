# ADR 0003: Storage axis — driver ABI, contract shape, and scope boundary

**Status:** proposed
**Date:** 2026-06-24
**Deciders:** @fujibee

## Context

[ADR 0002](0002-driver-discovery-and-plugin-opt-in.md) established the
axis-generic driver registry and external-plugin opt-in. Making the message
store pluggable needs three architectural questions locked before any driver is
written, because each of them is expensive to reverse once a store exists:
what a driver is allowed to expose, what core is allowed to ask for, and where
the storage axis stops.

An independent design pass converged with an earlier one and corrected an
initial lean toward a subcommand ABI; this ADR records the converged decisions.
ADRs are revisable, so it reaffirms or tightens
[ADR 0001](0001-storage-driver-pluginization.md) where that is the better
choice.

## Decision

1. **Drivers stay sourced bash, behind a *locked* ABI.** Keep ADR 0001's
   sourced-function model, but tighten it: a driver exposes only the `storage_*`
   domain operations and must not leak SQL fragments, file paths, or backend
   cursors to core. A backend that is not bash is reached by a thin bash facade
   that shells out to it. A subcommand + JSONL-pipe protocol is reserved as an
   *internal* form a facade may exec later if a driver truly cannot be bash — it
   is **not** promoted to the core ABI now.

2. **The contract abstracts use-cases, not queries.** Core calls domain
   operations (send / list-unread / mark-read / watch-after / history), never a
   query language. Two consequences: (a) the watch/check-inbox replay checkpoint
   is an **opaque, driver-issued delivery cursor**, kept separate from read
   state — core never compares it, so a backend may order by an integer, a
   time-ordered id, or a byte offset in an append log without core knowing
   which; (b) read-marking is recipient-scoped and idempotent. This removes any
   `id > watermark` assumption from core, which would otherwise hold only for
   backends whose ids happen to be comparable integers. The canonical
   export/import format is a JSONL event log.

3. **The storage axis is a message store, and stops there.** The team registry
   and run-state — pidfiles, watch watermarks, actas locks, ready sentinels —
   are not part of it, and a driver that moves the message store onto a network
   does not carry them along. Those raise distributed-lease, TTL, clock, and
   orphan-reclaim concerns that belong to a **coordination axis** under its own
   ADR, if multi-host coordination is ever wanted.

## Alternatives considered

- **Subcommand + JSONL pipe as the core driver ABI.** Cleaner process boundary
  and language-agnostic, but a non-bash backend runs its own process inside the
  driver regardless, so piping the core↔driver boundary adds call-path
  complexity (and an extra fork on the unread/insert hot path) before any real
  benefit. Two independent design passes both landed on sourced; kept as a
  deferred internal-implementation option.
- **Structured query params with a single core-comparable watermark.** Rejected
  the comparable watermark — any cursor core can compare leaks the backend's id
  scheme. The opaque-cursor decision generalizes it.
- **A networked store as full shared state (messages + registry +
  coordination).** Rejected: it balloons into distributed coordination, which
  decision 3 splits to a future axis.

## Consequences

- Positive: one ABI serves any backend with no core changes; the opaque cursor
  and the use-case contract make a new backend a self-contained driver; the
  default install is unchanged; it aligns with ADR 0002's registry and opt-in.
- Negative: core code that assumes one backend's own id column and read-marking
  shape must move behind the contract before any second driver works. Sourced
  drivers keep ADR 0002's trust concern, mitigated by opt-in and the `storage_*`
  prefix discipline.
- Neutral: the subcommand+pipe protocol and multi-host coordination are
  explicitly *deferred, not rejected* — each can land under a later ADR.

## References

- Builds on [ADR 0001](0001-storage-driver-pluginization.md) and
  [ADR 0002](0002-driver-discovery-and-plugin-opt-in.md).
- The `storage_*` signatures live in the spec, not this ADR:
  [`docs/spec/driver-interface.md`](../spec/driver-interface.md).
