# Stage-2 read-state synchronization specification

**Status:** dogfood specification
**Last updated:** 2026-07-25

The irreversible read-state semantics behind this contract are recorded in
[ADR 0006: Composite read-state frontier](../../adr/ref/0006-composite-read-state-frontier.md).

## Context

Stage 1 deliberately separates remote transport progress, decrypt/import state,
and user or agent read state. The first two layers synchronize, but read state
is still machine-local. A message read on one device can therefore be delivered
again on another device.

The older Phase-3 storage-cursor branch used one scalar local-log position per
`(team, agent)`. That scalar cannot represent read state in a local-first remote
store. For example, an unread, unacknowledged local message may be at local
position 5 while a remote message at server sequence 10 is imported at local
position 6. Translating a remote read frontier of 10 into local position 6 would
hide the unread local message. Refusing to translate it would redeliver the
remote message.

## Decision

### Store-owned composite frontier

Each storage driver composes two independently scoped layers:

- the local layer, keyed by `(driver_generation, local_team_identity,
  local_agent_identity)`, contains `local_position`, the contiguous covered
  prefix of that store's message order, plus exact local reads keyed by stable
  local message ID; and
- the remote overlay, keyed by `(server_instance_id, remote_team_id,
  protocol_version, member_id)`, contains `remote_server_seq`, the contiguous
  covered prefix of that immutable remote stream, plus exact remote reads keyed
  by wire ID.

A projected message is read for an agent when at least one of these facts covers
that message itself:

1. its local position is at or below `local_position`;
2. it has a durable mapping whose `server_seq` is at or below
   `remote_server_seq`; or
3. its stable local ID or wire ID is in the corresponding exact-read set.

The driver MUST NOT infer remote coverage for a local message without a durable
wire/sequence mapping. Local read progress survives remote binding replacement
because it is not binding-scoped. A previous binding's remote overlay may remain
durable for audit/recovery, but it is neither copied into nor consulted by a new
binding. Coverage composes the one local layer with only the currently active
binding/member overlay selected by authenticated sync configuration.

The local team name and mutable member name are not remote identities. A roster
name is associated durably with its immutable `member_id`; rename preserves the
association, and retired names cannot be rebound as required by HTTP v1.

The v1 bundled local drivers do not yet assign separate UUIDs to local teams or
agents, so `local_team_identity` and `local_agent_identity` are their normalized
names within the persistent driver generation. A successful local rename MUST
atomically migrate the message projection, exact local reads, local frontier,
and active member association to the new name in the same storage transaction.
It MUST NOT create a fresh read layer or reuse a retired name. A future stable
local UUID may replace this rename discipline without changing the remote key.

The transport cursor, quarantine/decrypt state, composite read state, and the
existing display/read receipt layer remain distinct. Receiving remote read
state never imports, decrypts, displays, or marks a blocking quarantine entry as
read. If reprocessing later imports that message and its sequence or wire ID is
already covered, the local projection starts read.

### Contiguous-prefix and exact-read rules

Neither frontier may jump over an uncovered message on its own axis. Reading a
later message creates an exact fact while the frontier remains immediately
before the first hole. Once the hole becomes covered, the driver compacts the
now-contiguous prefix and may discard absorbed synchronization exceptions.

For example, if local position 5 is unread and position 6 is read, position 6 is
an exact read and `local_position` remains 4. Reading position 5 permits a
single transaction to advance the local frontier to 6 and compact the absorbed
exact fact. The same prefix-plus-exceptions rule applies to `server_seq`.

The merge algebra is deliberately monotonic:

- remote frontiers merge with `max`;
- exact wire reads merge with set union; and
- local frontiers advance only inside their originating store through local
  contiguous compaction and are never merged between machines.

Read undo is not part of Stage 2. A future non-monotonic unread feature would
need an explicit generation or epoch rather than weakening these rules.

### Local consume contract

The required storage ABI adds:

```text
storage_read_cursor_get <team> <agent>
storage_read_cursor_consume <team> <agent> <delivery-cursor> [<id> ...]
```

`storage_read_cursor_get` returns the opaque local-position component.
`storage_read_cursor_consume` records the exact displayed IDs and advances the
local component only through a contiguous, successfully scanned delivery
prefix. Drivers MUST max-merge it and MUST NOT move it backwards.

Inbox, turn-hook, and monitor delivery use the same stored cursor. A successful
scan advances it even if the scanned span contains no message for the agent.
The monitor's former per-session watermark is no longer read authority.

An upgrade from the pre-cursor model treats the existing backlog as consumed to
avoid a full-history monitor storm. A fresh local layer begins at zero; its
remote overlay follows the authenticated retention-floor rule below. Messages
that arrive after migration remain unread.

### Retention floor

The authenticated `min_available_seq` is a safe lower bound for remote read
state because the inclusive retained prefix can never again be transported or
projected. For every member, the effective remote frontier is therefore
`max(stored_remote_server_seq, min_available_seq)`. A new read-state row or a
new device starts at the authenticated floor, not at zero when the floor is
nonzero. This is a server fact, never a client guess.

Prepare begins its contiguous proof at that effective frontier and requires
durable outcomes only for later sequences. Apply stores the response floor and
frontier atomically before using them for coverage. A stale response whose floor
or current sequence contradicts the authenticated binding snapshot is terminal.

Retention already locks the team sequencing row while it creates permanent
tombstones, deletes the covered message prefix, and advances
`min_available_seq`. In that same transaction it MUST max-merge every stored
member frontier to the new floor and remove exact rows whose live `team_seq` or
tombstone `original_seq` is now covered. Members without stored rows acquire the
floor logically on response/bootstrap. A migration regression MUST cover a new
device joining after a nonzero floor and continued compaction above that floor.

### Wire-ID promotion and atomicity

An exact read of a local-only message is initially keyed by its stable local
message ID. Publishing a Stage-1 reservation or reconciling a pull mapping MUST,
in the same storage transaction, promote or alias that read fact to the durable
wire ID. The promoted fact becomes eligible for upload only after the mapping
has a canonical acknowledged `server_seq`; a server MUST NOT be asked to store
an exact read for a wire ID it does not yet know.

Message import or mapping, exact-read promotion, frontier compaction, and any
covered projection change that they enable are one local transaction. Durable
covered rows and exact facts are written before either frontier advances. A
crash rolls the whole transition back, and replay is idempotent.

An exact remote fact may arrive before its message. The driver stores it by wire
ID without fabricating a local projection. Import later applies the fact only
after the envelope has passed policy/decrypt validation and has been durably
projected.

### Optional Stage-2 driver operations

A Stage-1 SQLite driver may advertise the additional
`stage2-read-state` capability and implement:

```text
storage_sync_prepare_read_state <local-team> <server-instance-id> <remote-team-id> <protocol-version>
storage_sync_apply_read_state <local-team> <server-instance-id> <remote-team-id> <protocol-version>
```

Both operations use UTF-8 JSONL on stdin/stdout. Prepare receives one validated
`sync_read_context` record containing the current immutable member IDs and
names, `min_available_seq`, and `current_seq` from one authenticated server
snapshot, plus `local_agents` from the local team registry as a separate
authority. Message sender/recipient strings are never roster evidence. It first
max-merges the remote overlay with the authenticated floor,
then emits zero or more `sync_read_frontier` and `sync_read_exact` records:

```jsonl
{"type":"sync_read_frontier","member_id":"018f...","server_seq":"42"}
{"type":"sync_read_exact","member_id":"018f...","wire_id":"550e8400-e29b-41d4-a716-446655440000"}
```

For each member, prepare computes the largest safe contiguous remote prefix. It
stops before any sequence whose envelope lacks a durable outcome, any blocking
quarantine entry whose recipient is unknown, or any imported message addressed
to that member that local read state does not cover. Imported messages for other
members are vacuously covered for this member. It emits exact wire reads above
the safe prefix only when their mappings and server sequences are durable.

Apply consumes one authenticated `sync_read_snapshot` record containing the
response `min_available_seq` and `current_seq`, followed by a page of server
`sync_read_frontier` and `sync_read_exact` records. In one transaction it
max-merges the floor and frontiers, set-unions exact facts, projects coverage
only onto already imported messages, compacts each local prefix, and removes
only exact facts whose own durable mapping proves
`server_seq <= remote_server_seq`. It MUST NOT garbage-collect by wire ID alone.
It never changes transport or decrypt/import progress.

### HTTP operation

`POST /v1/read-state/sync` uses the normal team credential and standard HTTP v1
binding/version rules. The strict request is:

```json
{
  "updates": [
    {
      "member_id": "018f3f7e-0000-7000-8000-000000000010",
      "server_seq": "42",
      "exact_wire_ids": ["550e8400-e29b-41d4-a716-446655440000"]
    }
  ],
  "page_after": null,
  "page_limit": 1000
}
```

`updates` contains at most 1,000 distinct active members, each exact list
contains distinct canonical UUIDv4 wire IDs, and the request contains at most
1,000 exact IDs in total. `server_seq` is a canonical signed-BIGINT decimal
string. `page_limit` is an integer from 1 through 1,000. `page_after` is either
null or the exact canonical item key returned by the previous response. A
frontier key is exactly `{"member_id":"...","kind":"frontier"}`; an exact key
is exactly `{"member_id":"...","kind":"exact","wire_id":"..."}`. The key is
a comparison boundary and need not still exist when the next page is read.
Unknown and duplicate fields are rejected under the common v1 JSON rules.

HTTP v1 bounds a team roster to 1,000 active members and rejects larger
operator provisioning documents atomically. The Stage-2 context therefore fits
in one authenticated roster response; the read-state item stream is still
paginated because each member can contribute bounded exact exceptions.

In one transaction the server:

1. locks the team row used by message and policy sequencing;
2. validates that every member is active in the credential's team, every
   frontier is at most `current_seq`, and every exact wire ID resolves to a live
   message or permanent tombstone in that team;
3. max-merges frontiers and set-unions exact reads;
4. removes an exact row only when the resolved live message `team_seq` or
   tombstone `original_seq` is at or below that member's merged frontier;
5. max-merges every stored frontier to at least `min_available_seq` and removes
   every exact row proven covered by the resulting effective frontier;
6. verifies the remaining exact set is at most 4,096 rows per member and 65,536
   rows per team, failing the entire update atomically with `409
   read-state-limit-exceeded` otherwise; and
7. reads the response page from the same snapshot.

The response contains one bounded page from a single canonical item stream.
Every active member contributes one `frontier` item, and every unabsorbed exact
row contributes one `exact` item:

```json
{
  "protocol_version": 1,
  "server_instance_id": "018f3f7e-0000-7000-8000-000000000000",
  "team_id": "018f3f7e-0000-7000-8000-000000000001",
  "team_name": "example-team",
  "min_available_seq": "0",
  "current_seq": "52",
  "items": [
    {"kind":"frontier","member_id":"018f3f7e-0000-7000-8000-000000000010","server_seq":"42"},
    {"kind":"exact","member_id":"018f3f7e-0000-7000-8000-000000000010","wire_id":"550e8400-e29b-41d4-a716-446655440000"}
  ],
  "next_page_after": {"member_id":"018f3f7e-0000-7000-8000-000000000010","kind":"exact","wire_id":"550e8400-e29b-41d4-a716-446655440000"},
  "has_more": true
}
```

Items are sorted by `(member_id, kind_order, wire_id)`, where `frontier` sorts
before `exact` and its wire component is empty. A member with no stored row has
the effective frontier `min_available_seq`. `items.length` never exceeds
`page_limit`; frontier cardinality is therefore bounded by the same pagination
contract as exact state. `next_page_after` is null exactly when `has_more` is
false, otherwise it is the final emitted item key.

Pagination is keyset-based. Each request is an independent current snapshot:
concurrent monotonic additions that sort before an in-progress page cursor may
be observed on the next poll. An exact row removed by GC is necessarily covered
by a frontier item; if that item was on an earlier page, the client has already
applied it, and otherwise it appears in the current or next polling cycle.
Member deletion is learned from the separately authenticated roster and retires
that member's local remote overlay. Clients apply every page monotonically and
restart at `page_after: null` on the next polling cycle.

Member rename is a two-sided handshake because local storage and the remote
operator roster cannot change atomically. The driver retains both the locally
confirmed agent name and the latest authenticated roster name for each immutable
member ID. While they differ, that member is durably blocked from emitting
frontier or exact mutations; message and other-member synchronization continue.
Either remote-first or local-first rename therefore fails closed until both
names agree. A name mismatch never authorizes advancing a remote frontier.

An empty update list is the read-only synchronization form. Retrying an update
is idempotent. The engine sends local updates with the first page request and
uses empty updates for subsequent pages. It validates response binding,
canonical ordering, limits, and pagination before giving a page to the driver.

The server schema is keyed by immutable `(team_id, member_id)` and
`(team_id, member_id, wire_id)`. Removing a member cascades its read state.
Member rename preserves it. A team credential may synchronize any active member
in its own team; cross-team access is impossible. Consequently, compromise of a
team credential can destroy unread availability for every member by advancing
their read state, in addition to reading and writing the team message stream.
Stage 2 does not claim per-member credential isolation.

### Limit failure and recovery

`read-state-limit-exceeded` is definitive and non-retryable without a state
change. The client retains every local frontier/exact fact, marks the identified
member's read synchronization as blocked, excludes that member from subsequent
mutation batches, and continues message push/pull plus read synchronization for
other members. It MAY continue read-only pagination so incoming remote facts are
not lost. It MUST NOT busy-retry the rejected update or discard exact facts.

The error details include the offending `member_id`, per-member and team counts,
and both limits. For a team-wide overflow the member is selected from the
current request's newly added exact facts, not merely from the largest existing
set, so iterative isolation converges. If the oldest hole is a normal imported unread message, operator
remediation is its ordinary authorized consume. If it is blocking quarantine,
the cause must be resolved and the envelope reprocessed so the frontier can
advance. The durable block is cleared only by the explicit operator command
`remote-sync.sh unblock-read --team NAME --member-id UUID`; the following
cycle either succeeds after remediation or durably blocks the member again. A
future explicit terminal/non-display disposition may provide another
monotonic remediation, but silently skipping poison or resetting read state is
forbidden.

### Explicitly out of scope

Stage 3 server-sent events and wake delivery are not launch requirements and are
not part of this specification. Stage 2 continues to use the existing polling loop. Stage
3 should treat SSE and mobile wake as one team-scoped notification layer: a
future iOS client may register an APNs device token, receive a Signal-style
silent push, then pull, decrypt, and produce a local notification. The server
still does not inspect recipients or message bodies.

## Consequences

- A read on one device converges monotonically on every device.
- Local-first messages are never hidden merely because a later remote sequence
  was read elsewhere.
- Out-of-order read state is bounded, paginated, and compacted only from proven
  wire-to-sequence mappings.
- The server stores member IDs, wire IDs, and numeric frontiers, but still
  cannot see sender, recipient, body, or client timestamps.
- Cursor synchronization cannot advance through an undecryptable envelope,
  because its recipient is unknown. Transport may continue independently.

## References

- [ADR 0003: storage-axis ABI](../../adr/0003-storage-axis-driver-abi-and-scope.md)
- [Stage-1 remote synchronization](stage-1-remote-sync.md)
- [ADR 0005: Remote synchronization contract](../../adr/ref/0005-remote-sync-contract.md)
- [HTTP API v1](../../../server/spec/v1.md)
