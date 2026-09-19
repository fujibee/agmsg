# ADR 0003: Storage axis — driver ABI, contract shape, and scope boundary

**Status:** proposed (draft — subject to change)
**Date:** 2026-06-24
**Deciders:** @fujibee

## Context

1.1.0 shipped the axis-generic driver registry and external-plugin opt-in
([ADR 0002](../0002-driver-discovery-and-plugin-opt-in.md)). 1.1.1 implements the
**storage axis** — the message store, made pluggable — with drivers `sqlite`
(default), `jsonl`+`duckdb`, and `redis`. Before writing code, three
architectural questions needed locking. An independent design pass (codex, this
session) converged with the earlier Fugu-demo design (codex + gemini) and
corrected an initial lean toward a subcommand ABI; this ADR records the
converged decisions. ADRs are revisable, so it reaffirms or tightens
[ADR 0001](../0001-storage-driver-pluginization.md) where that is the better choice.

## Decision

1. **Drivers stay sourced bash, behind a *locked* ABI.** Keep ADR 0001's
   sourced-function model, but tighten it: a driver exposes only the `storage_*`
   domain operations and must not leak SQL fragments, file paths, or backend
   cursors to core. Non-bash backends are reached by a thin bash facade that
   shells out (duckdb, redis-cli, a helper). A subcommand + JSONL-pipe protocol
   is reserved as an *internal* form a facade may exec later if a driver truly
   can't be bash — it is **not** promoted to the core ABI now.

2. **The contract abstracts use-cases, not queries.** Core calls domain
   operations (send / list-unread / mark-read / watch-after / history), never a
   query language. Two consequences: (a) the watch/check-inbox replay checkpoint
   is an **opaque, driver-issued delivery cursor**, kept separate from read
   state — core never compares it, so it absorbs sqlite int ids, UUIDv7, Redis
   stream ids, and JSONL offsets; (b) read-marking is recipient-scoped and
   idempotent. This removes the `id > watermark` (integer-id) assumption that
   currently lives in core and would break on UUIDv7 / Redis streams. The
   canonical export/import format is a JSONL event log.

3. **Redis (1.1.2) is a message store only.** The team registry and run-state
   (pidfiles, watch watermarks, actas locks, ready sentinels) are *not* moved
   onto the network with it — those carry distributed-lease / TTL / clock /
   orphan-reclaim concerns beyond the storage axis. Multi-host coordination, if
   wanted, becomes a separate **coordination axis** under its own ADR. Redis
   enters as a remote message bus, not as shared everything.

**Phasing:** 1.1.1 = storage facade + `sqlite` driver + `jsonl`(+`duckdb`)
driver (duckdb an opt-in query accelerator; default install stays bash +
sqlite). 1.1.2 = `redis` (message store).

## Alternatives considered

- **Subcommand + JSONL pipe as the core driver ABI.** Cleaner process boundary
  and language-agnostic, but the inner sqlite3/duckdb/redis-cli process runs
  inside the driver regardless, so piping the core↔driver boundary adds
  call-path complexity (and an extra fork on the unread/insert hot path) before
  any real benefit. Independent codex and the Fugu design both landed on sourced;
  kept as a deferred internal-impl option.
- **Structured query params with a single core-comparable watermark.** Rejected
  the comparable watermark — any cursor core can compare leaks the backend's id
  scheme. The opaque-cursor decision generalizes it.
- **Redis as full shared state (messages + registry + coordination).** Rejected
  for 1.1.2: balloons into distributed coordination; split to a future axis.

## Consequences

- Positive: one ABI serves sqlite / jsonl-duckdb / redis with no core changes;
  opaque cursor + use-case contract make a new backend a self-contained driver;
  default install unchanged; aligns with ADR 0002's registry + opt-in.
- Negative: core code that assumes the integer `messages.id` / `read_at` column
  must move behind the contract before any non-sqlite driver works (the bulk of
  1.1.1 — #203/#204/#206). Sourced drivers keep ADR 0002's trust concern,
  mitigated by opt-in + the `storage_*` prefix discipline.
- Known gap (not yet migrated, tracked for a follow-up): `rename.sh` /
  `rename-team.sh` rewrite historical `from_agent`/`to_agent`/`team` values by
  running `UPDATE` directly against the sqlite driver's own `messages` and
  `events` tables — bypassing the contract entirely, guarded only by "does the
  sqlite db file exist". A team/agent renamed while a non-sqlite driver is
  active gets its live registry entry renamed correctly, but the driver's
  historical message log is not — no contract function exists yet for
  "rewrite a name across history" (`storage_send`/`storage_history`/etc. all
  operate on messages, not identities). `api.sh`'s `get teams <team> messages`
  read path has the same coupling for a different reason: it needs
  `--before-id` cursor pagination `storage_history` does not expose, so it
  runs its own event-log ∪ legacy-table query rather than the facade function
  — correct today (it still reads driver-shaped tables, not different ones),
  but it too would need a driver-contract addition (a paginated history op) to
  stop assuming sqlite's schema shape under a non-sqlite driver.
- Neutral: the subcommand+pipe protocol and multi-host coordination are
  explicitly *deferred, not rejected* — each can land under a later ADR.

## References

- Builds on [ADR 0001](../0001-storage-driver-pluginization.md) and
  [ADR 0002](../0002-driver-discovery-and-plugin-opt-in.md).
- Spec (where the `storage_*` signatures live, not this ADR):
  [`docs/spec/driver-interface.md`](../../spec/driver-interface.md).
- Implementation: #51 (epic), #203 (contract), #204 (facade + sqlite),
  #205 (event-log), #206 (call-site migration), #207 (jsonl+duckdb), #208 (redis).
