# ADR 0005: Remote synchronization contract

**Status:** proposed (dogfood architecture)
**Date:** 2026-07-25
**Deciders:** @fujibee

## Context

agmsg is local-first: sending, reading, and agent execution must continue when
the network or remote service is unavailable. Remote synchronization therefore
cannot be a second message authority or a network dependency on the local hot
path.

Once shipped, changing wire identity, acknowledgement replay, cursor meaning,
retention-gap handling, or the server's interpretation of an envelope would
require storage migration, protocol compatibility, and reinterpretation of
past data. Those semantics belong in an ADR; endpoint shapes, record framing,
limits, and CLI flows live in versioned specifications.

## Decision

### Local durability is authoritative

The send hot path commits only to the local store. A synchronization driver
publishes a wire ID and its complete envelope durably before the HTTP engine can
observe either. A published wire ID always reuses byte-identical envelope bytes;
crash recovery never encrypts a second envelope under that identity.

Server acknowledgements are applied atomically and advance only the
acknowledged contiguous prefix of local messages. A later acknowledgement
cannot skip an earlier local hole. Pull advances only after every preceding
envelope in the page has a durable local outcome: imported, reconciled,
quarantined, or terminally corrupt.

The immutable binding identity is
`(server_instance_id, remote_team_id, protocol_version)` plus the storage
driver's persistent generation for interpretation of local positions. Endpoint
location and credential rotation do not change stream identity. A different
server instance, remote team, protocol, or local position generation is a
different synchronization namespace.

A device credential is bound to its endpoint origin, server instance, remote
team, and non-secret `credential_id`. It cannot authorize a different binding,
and revocation targets `credential_id`, never the bearer secret as an object
identifier. Secret single-delivery and provisional activation/finalization are
pinned by the onboarding API specification; an acknowledged secret is never
reissued after response loss.

### At-least-once transport has exact conflict semantics

Wire UUID deduplication is permanent:

- the same UUID and immutable envelope returns the original sequence;
- the same UUID with different immutable content is a terminal conflict;
- tombstones preserve the UUID, original sequence, and digest after live
  envelope retention;
- existing-ID lookup precedes current write-policy checks;
- a batch is all-or-nothing and acknowledgements map to input order.

This is at-least-once delivery with durable deduplication, not a claim of
"roughly exactly once." Per-team sequence allocation is serialized and
transactional so commit order is the team order. Numeric gaps may exist; a
cursor means "items ordered after this token," not "the next consecutive
integer."

A pulled echo of a locally pushed wire reconciles the existing local mapping.
It never creates a second local event. Any mismatch in wire, sequence, or
immutable envelope becomes durable `corrupt_state`.

### The server stores one opaque envelope shape

Plaintext profile `none` and encrypted profiles use one cipher-independent
message schema and the same sequencing, retention, idempotency, and policy
path. Sender, recipient, body, and client creation time remain inside the
envelope even for `none`. Projection, recipient filtering, search, and
per-agent wake decisions stay local.

The synchronization server never chooses team keys and never receives plaintext
private team or recovery keys. Sealing and opening happen client-side. This is
a content-confidentiality boundary, not an anonymity claim: team identity, wire
ID, sequence, server receipt time, envelope version, cipher, key epoch, digest,
size, timing, and traffic frequency remain visible as defined by the protocol.

### Progress layers remain independent

Transport progress, decrypt/import progress, and member read progress are three
separate durable layers. Transport may advance after durable quarantine while a
key is missing. Reprocessing may later import without rewinding transport.
Import never marks a message read.

HTTP `410 resync-required` proves that a range is no longer transportable.
Ordinary polling never assigns the authenticated retention floor to the pull
cursor. Only an explicit recovery operation may:

1. re-read and validate the authenticated binding and floor;
2. reproduce the retention gap from the exact stored cursor;
3. atomically append an immutable gap audit; and
4. advance only the transport cursor to that floor.

Local messages, projections, quarantine, decrypt state, read state, and
cryptographic trust checkpoints remain untouched. Retry after response loss
converges by looking up the durable audit rather than requiring the old cursor
again.

### Onboarding cannot overstate history durability

A successful credential connection is not proof that local history is durable
on the server. When onboarding backfills an existing store, retention cannot
drop a range required by the promoted snapshot until the server has the
manifest's terminal durable acknowledgement.

Proofs over local source identities and proofs over translated wire identities
use separate domains. They are never compared or reused as if translation
preserved identity bytes.

## Failure scenarios that fix the boundary

- **Ack before echo / echo before ack.** Merely excluding rows that already
  contain a server sequence does not close the race. Both arrival orders must
  reconcile the same durable mapping and produce one local event.
- **Automatic floor reset.** Setting cursor 42 directly to floor 100 would
  claim that 43–100 were fetched and durably classified. That false claim would
  propagate into E2EE, read state, and local history.
- **Separate plaintext path.** Adding server-side `from`, `to`, or body indexes
  would make enabling encryption remove features and would duplicate the most
  failure-sensitive sequencing and retention logic.
- **Global database sequence as stream order.** Concurrent transactions may
  commit in the opposite order from allocated global IDs. Team ordering must
  serialize at a team-local transaction point.

## Rejected alternatives

- **Network-backed send.** Rejected because remote availability would become a
  prerequisite for local agent work.
- **Reserialize on retry.** Rejected because randomized encryption under one
  wire identity would make retries conflict with themselves.
- **Cursor equals maximum observed sequence.** Rejected because it advances
  past local durability holes.
- **Automatic retention recovery.** Rejected because unavailable history is
  loss requiring explicit acknowledgement, not a successful pull.
- **Plaintext-only projections or a parallel table.** Rejected because E2EE
  would become a feature downgrade and two implementations would diverge.
- **Implicit full-history durability at connect.** Rejected because credential
  activation and history backfill have different crash boundaries.

## Consequences

- Local operation remains available during network failure.
- Drivers must implement atomic reservations, reconciliation, quarantine, and
  cursor transitions in their own storage model.
- Permanent tombstones grow with total historical message count.
- Explicit resync preserves auditability but requires operator confirmation
  after an unavailable interval.
- The remote service cannot offer server-side recipient delivery or body
  search without a future, explicit architecture change.

## Normative specifications

- [HTTP API v1](../../../server/spec/v1.md)
- [Stage-1 local-first remote synchronization](../../spec/ref/stage-1-remote-sync.md)
- [Cipher-independent opaque-envelope server schema](../../spec/ref/server-opaque-envelope.md)
- [Retention-gap resynchronization](../../spec/ref/retention-gap-resynchronization.md)
- [Storage driver interface](../../spec/driver-interface.md)
- [age-v1 profile](../../spec/ref/age-v1-profile.md)
