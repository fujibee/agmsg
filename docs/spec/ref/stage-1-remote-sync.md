# Stage-1 local-first remote synchronization specification

**Status:** dogfood specification
**Last updated:** 2026-07-25

The irreversible architectural decisions behind this contract are recorded in
[ADR 0005: Remote synchronization contract](../../adr/ref/0005-remote-sync-contract.md).

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

A storage driver may advertise the Stage-1 extension and implement these four
operations in addition to the ADR 0003 ABI:

```text
storage_sync_prepare_push <local-team> <server-instance-id> <remote-team-id> <protocol-version> <limit>
storage_sync_reconcile_push <local-team> <server-instance-id> <remote-team-id> <protocol-version>
storage_sync_apply_pull <local-team> <server-instance-id> <remote-team-id> <protocol-version>
storage_sync_reprocess <local-team> <server-instance-id> <remote-team-id> <protocol-version> <limit> [<page-after>]
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

### JSONL journal realization (Gate C)

The bundled JSONL driver realizes the same contract without a mutable sidecar
database. `events.jsonl` is the single append journal for local events and sync
state. Its Stage-1 local position is the byte offset immediately after the
originating top-level `message_sent` record, paired with a persistent file
generation. This sync position is separate from the driver's ordinal delivery
cursor.

Every Stage-1 operation holds the existing `events.jsonl.lock`, reads a complete
snapshot through its locked EOF, folds the immutable state records, and appends
at most one complete transition record with one append write followed by
`fsync`. Reservation, acknowledgement, quarantine/import outcomes, and the
transport cursor therefore become durable together. A pull page is one
`sync_pull_commit`; imported local events are nested in that record and the
normal inbox/history projection exposes each first committed local event once.
Replay commits carry no second local event.

Compaction and local rename preserve every sync record and rotate the file
generation because byte offsets may change. The replacement journal contains
the new generation before its atomic rename, so there is no rewritten-file /
old-generation crash window. Durable reservations retain their
local-ID/wire-ID/envelope identity across that rewrite. Position aliases permit
an acknowledgement already in flight for the preceding generation to reconcile
the same reservation, while the current generation's position is used for the
new contiguous push prefix. A rewrite never creates a new wire ID or envelope
for an existing reservation.

### Prepare push

`storage_sync_prepare_push` reads one `sync_prepare` JSONL record from stdin.
It contains the engine's validated envelope selection and capability limits,
but no credentials. The ABI is cipher-neutral: the driver creates the canonical
envelope selected by the binding configuration. `none` is the default profile.
The optional `age-v1` profile defined in
[`../spec/ref/age-v1-profile.md`](../../spec/ref/age-v1-profile.md) performs its
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

Reprocess output is stable keyset pagination ordered by `(server_seq, wire_id)`.
Each page contains at most `limit` `sync_reprocess_candidate` records and exactly
one final `sync_reprocess_page` record:

```json
{"type":"sync_reprocess_page","next_after":"42:550e8400-e29b-41d4-a716-446655440000","has_more":true}
```

`next_after` is the canonical decimal server sequence, a colon, and the lowercase
UUIDv4 wire ID of the last candidate. It is non-null exactly when `has_more` is
true. The engine supplies it unchanged as the optional `page-after` argument and
MUST reject a non-advancing, repeated, oversized, or malformed page. One explicit
reprocess invocation walks pages until `has_more=false`; permanently blocking
records in an early page therefore cannot starve a later newly recoverable record.
Transport cursor and driver generation MUST remain unchanged across the walk.
Candidate rows and the page trailer MUST come from one storage snapshot. Across
the complete walk, each `server_seq` occurs at most once. The engine bounds both
candidate and page counts by the authenticated lifetime sequence space: the
locally retained prefix through `min_available_seq` plus the available suffix
through `current_seq` (with at most one final empty page). This keeps a corrupt
driver from manufacturing an unbounded walk with ever-changing wire IDs.

The retention-gap specification promotes the previously reserved recovery operation behind a separate
optional `stage1-resync` capability:

```text
storage_sync_resync       # operator-approved recovery after HTTP 410
```

HTTP 410 remains terminal during normal Stage-1 polling. Only the explicit
operator command defined by the retention-gap specification may transactionally record the unavailable
gap and advance to an authenticated retention floor; the engine never resets a
transport cursor automatically.

## Consequences

- A send stays a local transaction; network failure cannot block the agent hot
  path.
- Crash recovery repeats durable reservations and acknowledgements instead of
  synthesizing new wire identities.
- The transport engine is backend-neutral, while each participating driver can
  make remote reconciliation atomic with its own local message store.
- SQLite and JSONL implement the dogfood contract. JSONL uses its locked,
  single-record append journal rather than emulating a mutable transaction
  outside the driver.
- The client downloads the whole team stream and projects recipients locally;
  the opaque envelope prevents server-side recipient routing.

## References

- [HTTP API v1](../../../server/spec/v1.md)
- [ADR 0003: storage-axis ABI and scope](../../adr/0003-storage-axis-driver-abi-and-scope.md)
- [Retention-gap resynchronization](retention-gap-resynchronization.md)
- [ADR 0005: Remote synchronization contract](../../adr/ref/0005-remote-sync-contract.md)
- Issue #441 (local-first cross-machine replication proposal)
