# ADR 0005: Stage-1 local-first remote synchronization

**Status:** proposed (dogfood contract)
**Date:** 2026-07-20
**Deciders:** @fujibee

## Context

The storage-axis ABI in ADR 0003 covers local message storage and delivery. It
does not define the crash boundaries needed to replicate a local-first store to
the versioned HTTP API in `server/spec/v1.md`. Stage 1 adds polling push/pull for
dogfood while keeping `storage_send` local and independent of network health.

The HTTP engine and the storage driver have different responsibilities. The
engine owns transport, authentication, capability and binding validation,
policy evaluation, retry classification, and polling. The driver owns every
local durability transition. In particular, the engine must never receive a
new wire ID or envelope that was not already committed locally, and it must
never advance a cursor ahead of durable local state.

## Decision

### Optional synchronization extension

A storage driver may advertise the Stage-1 extension and implement these three
operations in addition to the ADR 0003 ABI:

```text
storage_sync_prepare_push <local-team> <server-instance-id> <remote-team-id> <protocol-version> <limit>
storage_sync_reconcile_push <local-team> <server-instance-id> <remote-team-id> <protocol-version>
storage_sync_apply_pull <local-team> <server-instance-id> <remote-team-id> <protocol-version>
storage_sync_reprocess <local-team> <server-instance-id> <remote-team-id> <protocol-version> <limit>
```

The SQLite driver is the Stage-1 implementation. Drivers that do not advertise
the extension remain valid local-only drivers. Core must fail clearly rather
than emulate these durability operations outside an unsupported driver.

The binding is keyed by immutable `server_instance_id`, the server's stable
team/stream ID, and protocol version. Endpoint URL is deliberately absent: the
same server database may move without invalidating its cursors. A different
instance at the same URL is a different binding. The local team name selects
local messages but is not the remote stream identity.

Binding arguments contain no credentials or other secrets. Authentication
material remains inside the HTTP engine. Bulk records never use argv: all input
and output use UTF-8 JSONL, one complete JSON object per line, so message data is
not exposed through `ps(1)` and is not bounded by `ARG_MAX`.

Each binding also records the storage driver's persistent generation. Every
local position is interpreted only together with that generation. Compaction
that preserves the driver's cursor space preserves the generation; replacement
or reinitialization of that position space creates a new generation. This
prevents a reused local position from inheriting stale remote state.

### Prepare push

`storage_sync_prepare_push` reads one `sync_prepare` JSONL record from stdin.
It contains the engine's validated envelope selection and capability limits,
but no credentials. The ABI is cipher-neutral: the driver creates the canonical
envelope selected by the binding configuration. `none` is the default profile.
The optional `age-v1` profile defined in
[`../spec/age-v1-profile.md`](../spec/age-v1-profile.md) performs its
encrypt-once operation at this same boundary. Prepare receives only the public
recipient manifest; age identity files remain in the HTTP engine's open path
and never cross the storage-driver boundary.

The input record fields are `type`, `envelope_v`, `cipher`, `key_id`,
`recipients`, `max_blob_bytes`, and `allow_new`. `recipients` is an empty array
for `none` and the public, immutable X25519 recipient manifest for `age-v1`.
Private identities and HTTP credentials are forbidden in this record.

The record also contains `allow_new`. When current policy or sequence exhaustion
blocks new writes, the engine sets it to false: prepare must still emit
`sync_state` so pull can continue, but must not reserve a new envelope. Write
eligibility is not pull eligibility; unsupported or policy-violating remote
envelopes still need durable quarantine and transport progress.

The driver emits one `sync_state` record followed by zero or more ordered
`sync_push_candidate` records. `sync_state` includes the driver generation and
durable pull transport cursor, allowing a cycle to begin without adding a
fourth state-read operation. Each candidate includes its opaque local position,
local ID, durable random wire ID, and exact envelope.

Reservation is atomic and re-entrant by `(binding, driver generation, local
position)`. Calling prepare again before reconciliation must emit the identical
wire ID and byte-identical envelope; it must not reserialize, re-encode,
re-encrypt, or reserve a second wire ID. Existing unacknowledged reservations
are emitted before new local positions.

For a randomized cipher, sealing precedes publication. A wire ID used during a
private sealing attempt is not a durable or observable reservation. The driver
publishes the wire ID and complete envelope together in one local transaction.
If the process fails before that transaction, recovery abandons the private
candidate and seals under a new wire ID. If it fails after commit, recovery
reuses the committed envelope byte-for-byte.

### Reconcile push

`storage_sync_reconcile_push` reads `sync_push_ack` records from stdin. The
engine supplies only a complete, order-validated server acknowledgement set.
The driver verifies that every wire ID and local position matches a durable
reservation, records the canonical server sequence, and advances the durable
push cursor in one transaction.

The push cursor advances only through the contiguous prefix of local message
positions whose reservations are acknowledged. A later acknowledgement cannot
skip an earlier unacknowledged message. Replaying the same acknowledgements is
idempotent; a conflicting server sequence is `corrupt_state`.

### Apply pull

`storage_sync_apply_pull` reads validated `sync_pull_message` records and one
final `sync_pull_cursor` record from stdin. The engine has already verified the
response binding, ordering, server policy, local security history, envelope
syntax, and (where supported) plaintext or ciphertext authenticity. Each
message still contains the unchanged wire envelope plus its evaluated import
state and an optional local projection.

The driver commits a page atomically:

1. Persist every unchanged wire envelope in quarantine, keyed uniquely by wire
   ID within the immutable binding.
2. If that wire ID already maps to the same immutable envelope, reconcile the
   server sequence onto the existing local record and do not create another
   local event. This is the push-echo path and is idempotent.
3. If no mapping exists and the evaluated state is importable, allocate one
   local ID, import one local message event, and persist the mapping in the same
   transaction.
4. If the mapping or quarantine contains a different immutable envelope, record
   `corrupt_state`; never import or expose it.
5. Keep blocking states such as `unsupported_cipher`, `pending_key`,
   `authentication_failed`, `malformed`, and `policy_violation` durable without
   importing them.
6. Advance the pull transport cursor only after every earlier sequence in the
   page has reached one of those durable outcomes.

The wire-ID unique index is independent of the local message-ID index. A pulled
echo therefore reconciles to its mapped local ID, while an unmapped remote
message receives a new local driver ID exactly once.

### Three independent progress layers

Remote transport progress, decrypt/import state, and user/agent read state are
separate. Pull may advance after durable quarantine even when a key is missing;
adding a key may reprocess quarantine without rewinding transport; importing a
message does not mark it read. Existing local `message_read` events remain the
read layer.

`storage_sync_reprocess` emits durable blocking envelopes without changing the
transport cursor. The engine reevaluates them against the current authenticated
policy and installed identities, then passes the outcomes through apply-pull's
existing atomic import transition. Reprocessing is explicit rather than part of
every polling cycle, so a permanently invalid ciphertext cannot cause an
automatic decrypt loop.

ADR 0009 promotes the previously reserved recovery operation behind a separate
optional `stage1-resync` capability:

```text
storage_sync_resync       # operator-approved recovery after HTTP 410
```

HTTP 410 remains terminal during normal Stage-1 polling. Only the explicit
operator command defined by ADR 0009 may transactionally record the unavailable
gap and advance to an authenticated retention floor; the engine never resets a
transport cursor automatically.

## Consequences

- A send stays a local transaction; network failure cannot block the agent hot
  path.
- Crash recovery repeats durable reservations and acknowledgements instead of
  synthesizing new wire identities.
- The transport engine is backend-neutral, while each participating driver can
  make remote reconciliation atomic with its own local message store.
- SQLite is the initial dogfood backend. JSONL remains local-only until it can
  provide the same atomic import and cursor guarantees.
- The client downloads the whole team stream and projects recipients locally;
  the opaque envelope prevents server-side recipient routing.

## References

- [HTTP API v1](../../server/spec/v1.md)
- [ADR 0003: storage-axis ABI and scope](0003-storage-axis-driver-abi-and-scope.md)
- [ADR 0009: retention-gap resynchronization](0009-retention-gap-resynchronization.md)
- Issue #441 (local-first cross-machine replication proposal)
