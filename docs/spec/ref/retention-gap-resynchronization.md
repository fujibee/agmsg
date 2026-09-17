# Operator-approved retention-gap resynchronization specification

**Status:** dogfood specification
**Last updated:** 2026-07-25

The irreversible cursor and audit semantics behind this operation are recorded
in [ADR 0005: Remote synchronization contract](../../adr/ref/0005-remote-sync-contract.md).

## Context

The HTTP v1 message stream returns `410 resync-required` when a client's
transport cursor predates the team's authenticated `min_available_seq`.
Stage 1 intentionally treats that response as terminal: silently assigning the
floor to the cursor would claim that unavailable messages had durable local
outcomes.

Self-hosted operators nevertheless need bounded live-envelope storage. A
device that was offline beyond retention must be able to resume without
deleting its local-first messages, existing remote projections, decrypt
quarantine, or read state. The missing server prefix cannot be reconstructed,
so recovery must record an explicit acceptance of that loss rather than call it
a successful import.

## Decision

### Explicit gap acceptance

`remote-sync.sh resync --team NAME --accept-floor SEQUENCE` is the only v1
operation that may recover a binding from `410 resync-required`. Invocation is
an operator approval; polling commands never call it automatically.

Before changing local state, the engine MUST:

1. load and validate the existing immutable binding;
2. obtain an authenticated capability snapshot;
3. call the read-only resync-status ABI to obtain the driver's current
   transport cursor and any audit record for the accepted floor, without
   publishing a new envelope;
4. reproduce `410 resync-required` by requesting that exact cursor;
5. validate the error binding and require the error floor, capability floor,
   and `--accept-floor` value to be identical; and
6. require `transport_cursor < min_available_seq <= current_seq`.

A stale approval, a changed binding, a non-410 response, or a floor that changes
during those checks is terminal and leaves local state unchanged. The operator
must inspect the new floor and invoke the command again. The sole exception is
an identical audit record returned by status: if its accepted floor equals the
operator argument and the current cursor is at least that floor, the command
returns the recorded result idempotently. It does not require the now-impossible
old-cursor 410 to be reproduced.

### Driver transaction and audit record

The optional `stage1-resync` capability adds:

```text
storage_sync_resync_status <local-team> <server-instance-id> <remote-team-id> <protocol-version> <accepted-floor>
storage_sync_resync <local-team> <server-instance-id> <remote-team-id> <protocol-version>
```

Status is strictly read-only. It emits one `sync_resync_status` containing the
current transport cursor and either the immutable audit whose accepted floor
matches the canonical `accepted-floor` argument or `audit: null`. It MUST NOT
reserve a wire ID, seal an envelope, initialize a new binding, advance a cursor,
or change any other storage state. This is the normative backend-neutral seam;
the engine never inspects a driver's database directly and never substitutes
the mutating Stage-1 prepare operation.

The status output is exactly one JSONL object with no duplicate or unknown
fields. A lookup without an audit is:

```json
{"type":"sync_resync_status","driver_generation":"018f3f7e-0000-7000-8000-000000000099","transport_cursor":"42","audit":null}
```

An accepted audit uses this strict shape:

```json
{"type":"sync_resync_status","driver_generation":"018f3f7e-0000-7000-8000-000000000099","transport_cursor":"100","audit":{"expected_transport_cursor":"42","accepted_floor":"100","gap_start":"43","gap_end":"100","reason":"retention-gap-accepted"}}
```

`driver_generation` is the non-empty, immutable generation identifier already
used by Stage 1 and is limited to 256 UTF-8 bytes without control characters.
All cursor/floor/gap fields are canonical nonnegative decimal strings no greater
than the signed 64-bit sequence maximum. The driver confines both cursor and
audit lookup to the argv binding and returned generation.

The engine MUST reject anything other than exactly one record and MUST reject
duplicate JSON keys, unknown fields at either object level, noncanonical values,
or a type other than `sync_resync_status`. For a non-null audit it also verifies:

- `audit.accepted_floor` equals the requested argv floor;
- `audit.gap_end` equals `audit.accepted_floor`;
- `audit.gap_start` equals `audit.expected_transport_cursor + 1` without
  overflow;
- `audit.expected_transport_cursor < audit.accepted_floor <= transport_cursor`;
  and
- `audit.reason` is exactly `retention-gap-accepted`.

`audit: null` is the only no-match representation; omitted audit fields or a
partial object are invalid.

The operation consumes exactly one UTF-8 JSONL record:

```json
{"type":"sync_resync","expected_transport_cursor":"42","min_available_seq":"100","current_seq":"123","reason":"retention-gap-accepted"}
```

This input is also strict: those five fields are required, no other or duplicate
fields are allowed, all three sequences follow the canonical signed-BIGINT
decimal rule, and
`expected_transport_cursor < min_available_seq <= current_seq`.

In one storage transaction, the driver MUST revalidate the binding and exact
expected cursor, insert an immutable audit record for the unavailable inclusive
range `43..100`, and advance the transport cursor to `100`. The audit has a
unique `(binding, driver generation, accepted floor)` lookup key and records the
old cursor. A conflicting record for the same accepted floor fails without
mutation.

The operation MUST NOT delete or rewrite local messages, remote projections,
wire mappings, acknowledgements, conflicts, quarantine entries, security
checkpoints, or read state. In particular:

- an unacknowledged local message remains eligible for byte-identical retry;
- a replay whose wire ID has become a server tombstone still reconciles to its
  original `server_seq`;
- existing blocking quarantine remains available to explicit reprocessing; and
- Stage-2 read state independently max-merges the authenticated retention floor
  under the read-state synchronization specification.

The transaction emits exactly one strict result object:

```json
{"type":"sync_resync_result","driver_generation":"018f3f7e-0000-7000-8000-000000000099","expected_transport_cursor":"42","transport_cursor":"100","accepted_floor":"100","gap_start":"43","gap_end":"100","reason":"retention-gap-accepted"}
```

No duplicate, unknown, or missing field is allowed. Its generation must equal
the preceding status generation, and its decimals/reason must satisfy the same
predicates as a non-null status audit, with
`transport_cursor == accepted_floor`. The engine validates the object before
reporting success.

If the process crashes after commit but before observing that result, the
repeated command obtains the immutable row through status, constructs this
exact same result shape, and returns it without requiring the old cursor as CLI
input. After a commit, a normal polling cycle starts at the floor and downloads
only `server_seq > min_available_seq`. No event is fabricated for the
unavailable range.

Drivers without `stage1-resync` remain valid Stage-1 drivers. The engine checks
the advertised capability before the operator command and fails without a
network or local mutation when it is absent.

### Reference-server retention configuration

The reference server accepts optional
`AGMSG_RETENTION_MAX_LIVE_MESSAGES=<positive integer>`. It is disabled when
unset. The value MUST be canonical decimal, positive, and no greater than the
signed 64-bit sequence maximum; an invalid value fails server startup before
listening. After a successful message batch has its canonical acknowledgements,
the same transaction and team-row lock advance the floor to
`max(existing_floor, current_seq - max_live_messages)` when needed, create
permanent digest tombstones, delete the covered live prefix, advance read
frontiers, and garbage-collect covered exact reads before commit.

The manual `npm run retain -- TEAM_ID THROUGH_SEQUENCE` operation remains
available and uses the same transactional primitive. Automatic and manual
retention therefore serialize with message sequence allocation and cannot
expose a floor without complete tombstones.

This setting bounds retained envelope payload rows, not all database bytes.
Permanent UUID/digest tombstones, credentials, membership, policy history, and
audit records remain durable protocol state. Operators must include that
metadata in capacity planning. A window smaller than an offline interval, or
small relative to a large active write batch, can force healthy clients through
410 recovery. The reference server MUST document this consequence and emit a
retention log or metric containing the team, old floor, new floor, and removed
live-row count without logging envelopes or credentials.

## Failure and retry semantics

- `once` and `run` continue to stop on 410 and log the authenticated floor.
- `resync` is safe to retry with the same accepted floor; an already committed
  identical audit record returns the same result even though the current cursor
  has advanced and the original 410 can no longer be reproduced.
- A crash before the driver commit changes nothing. A crash after commit leaves
  the advanced cursor and audit row together, so the next poll resumes safely.
- Resync never weakens age-v1 anti-rollback checkpoints or cipher policy.

## Consequences

- Offline devices can recover from self-host retention without a destructive
  local-store replacement.
- The UI and logs can distinguish imported history from an operator-accepted
  unavailable interval.
- Recovery accepts irreversible message loss for the missing server interval;
  it cannot promise a full snapshot that HTTP v1 does not provide.
- Live payload retention is configurable while permanent idempotency metadata
  preserves exactly-once replay behavior.

## References

- [Stage-1 remote synchronization](stage-1-remote-sync.md)
- [Stage-2 read-state synchronization](read-state-synchronization.md)
- [ADR 0005: Remote synchronization contract](../../adr/ref/0005-remote-sync-contract.md)
- [ADR 0006: Composite read-state frontier](../../adr/ref/0006-composite-read-state-frontier.md)
- [HTTP API v1](../../../server/spec/v1.md)
