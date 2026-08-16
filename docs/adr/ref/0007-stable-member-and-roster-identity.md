# ADR 0007: Stable member and roster identity

**Status:** proposed (design architecture)
**Date:** 2026-07-25
**Deciders:** @fujibee

## Context

Names, installations, project placements, and remote bindings all change over
time. Treating any of them as the identity of a team member would rewrite the
meaning of historical messages, read facts, and authorization when a rename,
device replacement, or reconnect occurs.

agmsg launch teams have exactly one human owner but may contain many agent
members. Owner identity and member identity are different security domains.
Changing these anchors after ship would require data migration and could
transfer historical authority, so the model belongs in an ADR. Onboarding
screens, command ordering, protocol phases, and progress UX remain editable
design/specification.

## Decision

### Distinguish every identity layer

- A **team owner** is the one human account authorized to control the hosted
  team. V1 has exactly one immutable owner. Pairing another device must prove
  the same owner; it is not an invitation for another owner. Server, CLI, and
  credential issuance all enforce this boundary.
- A **local team identity** is a stable opaque UUID created locally. It is not
  the team display name and is not the remote binding ID.
- A **member** is an agent principal anchored by stable opaque `member_id`.
  Its display name is mutable metadata.
- A **registration** is the portable logical registration of a member.
- An **installation** is device-scoped state and is not portable member
  authority.
- An **agent placement** associates a member with a local project/runtime. It is
  not the member catalog itself.
- A **remote binding** maps a stable local team to a remote team/stream. Promote
  creates that mapping; it never retrofits the local UUID onto the remote ID.

No field reserved for a future multi-owner, channel, or space model is inferred
into v1. Future room-like collaboration must use a separate namespace and
explicit authorization model rather than weakening the single-owner team
boundary. Granting another human access is never modeled as merely delivering
the existing team key. Identifier, key-domain, protocol-resource, and log-path
namespaces remain non-conflicting with future containers; envelopes and cipher
profiles are versioned, and exports preserve which container produced them.

### Legacy state must acquire its local identity exactly once

Existing team configurations predate the opaque local team identity and contain
only a mutable name. Migration assigns one local team UUID exactly once and
commits every local reference to that identity through an atomic staging-and-
flip or a resumable migration with equivalent crash guarantees. Collision,
partial migration, or contradictory retry state fails closed.

Rename, promotion, and member mutation cannot begin until the identity migration
is complete. Export and import preserve the local team ID; intentionally copying
or forking a team creates a new ID instead of cloning authority. The migration
implementation and recovery contract must land in the same train as this
decision; the architecture is not accepted without a path for existing teams.
UUID version, field names, and storage mechanics remain specification details.

### Names never become identity

Rename preserves `member_id`, historical sender/recipient attribution, read
authority, and cryptographic identity. Active and retired names form an
ordered identity history. Removal retires an identity; it does not rewrite old
messages or free the old identity for silent reuse.

When concurrent creators propose the same normalized new name, the first
accepted `member_id` is canonical. Another ID is not merged by name. A local
member awaiting remote acceptance remains `pending_remote_acceptance` and
cannot act, send, create read facts, or participate in Stage 1 or Stage 2 until
the server accepts that identity.

### Roster mutations converge by dedupe then revision order

Every roster mutation has immutable `mutation_id` and canonical request digest.
The server checks for a stored mutation result before applying
`members_revision` compare-and-swap. This ordering makes acknowledgement-loss
retry return the original result instead of turning success into a revision
conflict.

New mutations use optimistic CAS on `members_revision`. Concurrent add, rename,
retire, and registration changes therefore acquire one total order. A stale
response is an acknowledgement fact, not permission to replace a newer local
catalog: local apply is monotonic and never rolls a higher revision backward.

Local identity history remains authoritative when a local team is first
promoted. The server validates and records the mapping but does not infer a
different roster from display names or opaque message projections.

### Authorization evolution is additive and fail-closed

V1 defines no member roles or permission fields. Member records and the roster
mutation protocol remain additively extensible for a future authorization
model, without guessing that model's fields now.

An authenticated authorization rejection is a definitive mutation outcome.
Clients never reinterpret an unknown denial as retryable success, resolve it by
last-writer-wins, or apply an optimistic local roster mutation after rejection.
The eventual wire spelling belongs in the versioned protocol specification.

### Lifecycle operations do not collapse domains

Leaving or deleting the last local agent placement does not delete the portable
member catalog, local team identity, remote binding, or team key. Rename and
retirement do not revoke device credentials. Credential revocation does not
rewrite or cryptographically erase a member's historical messages.

Two independently populated teams are never merged implicitly. A reconnect may
reattach only with exact prior identity and binding proof. Any future populated
to populated merge requires a separately specified identity and history
reconciliation protocol; matching display names are insufficient.

## Failure scenarios that fix the boundary

- **Name as identity.** Retiring `alice` and later creating a new `alice` would
  transfer old read facts and message attribution to a different principal.
- **Remote ID as local authority.** Reconnecting to a replacement service would
  redefine the identity of local history.
- **Partial legacy migration.** A crash assigns an ID to team `main` before
  migrating read and history references. Retry assigns or adopts another ID,
  splitting old messages and the remote mapping across two team identities.
- **CAS before mutation dedupe.** A successful mutation whose response was lost
  would retry against a newer revision and report conflict instead of its
  stored success.
- **Installation as portable registration.** A second device would materialize
  another machine's private placement and confuse device lifecycle with member
  authority.
- **Act before remote acceptance.** A losing concurrent member ID could publish
  messages or reads that no accepted principal can later own.
- **Merge by name.** Two populated stores may use the same name for different
  principals and histories; last-writer-wins would silently rewrite one truth.
- **Authorization denial as retry.** A future server denies rename by policy,
  but an old client retries or commits its optimistic local rename, diverging
  authorization and historical identity.

## Rejected alternatives

- **Mutable display name as primary key.** Rejected because rename and reuse
  reinterpret history.
- **Remote team ID as the local team ID.** Rejected because local authority
  exists before connection and must survive rebind.
- **Lazy team-ID assignment during promotion.** Rejected because crash retry
  could split legacy references or derive local authority from the remote ID.
- **One catalog containing registrations, installations, and placements.**
  Rejected because portable identity and machine-local lifecycle have different
  authority and privacy.
- **Last-writer-wins roster merge.** Rejected because it loses accepted
  concurrent mutations and makes acknowledgement retry non-convergent.
- **Implicit populated-to-populated merge.** Rejected until an explicit
  identity/history reconciliation protocol exists.
- **Treat removal as credential revocation or erasure.** Rejected because
  membership, device authorization, and ciphertext history are separate facts.

## Consequences

- Rename, reconnect, and device replacement preserve historical meaning.
- Existing name-only teams require a fail-closed, crash-safe identity migration
  in the same delivery train.
- Roster storage must retain stable IDs and ordered active/retired identity
  history.
- New members on remote-bound teams may wait for server acceptance before use.
- Local placement cleanup cannot double as team or member deletion.
- Multi-owner collaboration, if introduced later, is additive rather than a
  reinterpretation of existing single-owner teams.
- Future authorization can extend the roster protocol without making legacy
  clients treat denial as success.

## Normative design and specifications

- [Remote sync design](../../design/remote-sync.md)
- [HTTP API v1](../../../server/spec/v1.md)
- [Stage-2 read-state synchronization](../../spec/ref/read-state-synchronization.md)
- [ADR 0005: Remote synchronization contract](0005-remote-sync-contract.md)
- [ADR 0006: Composite read-state frontier](0006-composite-read-state-frontier.md)
