# Cipher-independent opaque-envelope server specification

**Status:** dogfood specification
**Last updated:** 2026-07-25

The irreversible architectural decision behind this schema is recorded in
[ADR 0005: Remote synchronization contract](../../adr/ref/0005-remote-sync-contract.md).

## Context

The remote protocol supports both plaintext (`cipher: "none"`) and encrypted
envelopes. It would be tempting to optimize the plaintext case by projecting
`from`, `to`, `body`, or client creation time into dedicated server columns and
indexes. That would make server-side recipient filtering and full-text search
easy for plaintext teams, but it would create two materially different remote
products and two storage paths.

The local store already owns message projection, recipient filtering, search,
read state, and per-agent wake decisions. The remote server's role is durable,
ordered replication of opaque team-stream envelopes.

## Decision

The reference server uses one cipher-independent messages schema and one code
path for every envelope. The server interprets only this message metadata:

- immutable team/stream identity;
- opaque wire ID;
- per-team sequence;
- server receipt time;
- envelope version, cipher identifier, and key ID;
- the canonical envelope digest required for idempotency.

The same row also stores the opaque envelope blob needed for replication. Its
bytes and size are visible operationally, but they have no server-side semantic
projection.

`from`, `to`, `body`, and client `created_at` are always inside the opaque blob,
including when `cipher` is `none`. The server does not project, parse, index, or
log them. Schema migrations MUST NOT add plaintext-only projections of these
fields to the remote messages table or a parallel plaintext messages table.

This is an architectural boundary, not merely an implementation preference:

1. **E2EE must not be a feature downgrade.** If plaintext teams gain remote
   recipient filters or body search, enabling encryption later removes features
   users already depend on. A cipher change should change only the envelope
   contents and local open operation, not the remote product surface.
2. **There is one correctness path.** A single schema and transaction path
   structurally avoid duplicated sequencing, retention, idempotency, policy,
   and authorization implementations—and the divergent bugs they would create.
3. **Opacity is auditable.** “The server does not know message contents” is
   enforced by the absence of content columns and indexes. Reviewers can verify
   the property from the schema and write path rather than trusting a runtime
   convention.

## Consequences

The remote service does not provide server-side recipient delivery, body
search, per-agent wake, or destination-specific stream filtering. Gate H8
therefore applies equally to `none` and encrypted ciphers: clients download the
team stream, durably quarantine envelopes, open them locally, and project them
into the local store. Team-wide polling or wake can reduce latency, but cannot
select recipients on the server.

This deliberately preserves the local-first division of responsibility. Local
`from` and `to` columns may be indexed and used for delivery because the local
store is the trusted projection boundary. Remote storage remains a replication
layer whose capabilities do not depend on whether an envelope is encrypted.

Server-visible metadata is not private. Team membership, wire IDs, sequence,
receipt time, cipher/key epoch, blob size, and traffic patterns remain visible;
this specification does not claim otherwise.

## Rejected alternative

### Plaintext projection schema or parallel plaintext table

Adding `from`/`to`/`body` columns and indexes only for `cipher: "none"` was
rejected. It would make encryption activation a loss of server features and
would require separate plain/encrypted write, retention, query, and migration
paths. Those costs and correctness risks outweigh the convenience of remote
filtering that the local store already provides.
