# Local-first onboarding and convergent roster design

> **SUPERSEDED.** The onboarding this describes was replaced by
> [`docs/design/remote-sync.md`](../remote-sync.md), which states the replacement
> from its own side. Kept as design history: the reasoning here is why the
> current shape is what it is, and the findings it records were closed rather
> than dropped. Do not build to it.

**Status:** design gate
**Last updated:** 2026-07-25
**Owner:** @fujibee

This is an editable onboarding and protocol design, not an architecture
decision record. Persistent member, roster, installation, and local/remote
identity semantics are recorded in
[ADR 0007: Stable member and roster identity](../../adr/ref/0007-stable-member-and-roster-identity.md).

## Context

The canonical product story is local-first:

1. install agmsg;
2. create a team and its members with the local CLI; and
3. connect that local team to a remote service.

A second, clean installation may join an already-promoted team by pulling its
canonical identity and retained history. Pull is a join operation; it never
creates a remote team. V1 does not merge two independently populated teams.

The current onboarding implementation has the opposite creation order. A server
operator first creates a team and provisions its roster, then issues a
team-scoped pairing token. The token exchange immediately creates an active,
team-bound credential. This assumption is present in the database as well as the
CLI: `pairing_tokens.team_id` and `credentials.team_id` are non-null references
to an existing team.

Adding one `promote` endpoint after that exchange would create two overlapping
onboarding state machines. It would leave unclear which operation creates the
team, how an unbound credential is authorized, how a client distinguishes
promotion from joining, and what survives a response-loss crash between those
steps.

At the same time, the existing implementation contains reviewed components that
must not be discarded:

- opaque, single-use, short-lived pairing tokens;
- independently revocable per-device credential IDs and secret digests;
- strict protocol, server-instance, team, capability, and response binding;
- private credential and key storage;
- Stage-1 durable reservation, full acknowledgement reconciliation, pull
  quarantine, and transport progress;
- Stage-2 read-state separation; and
- the `none` and `age-v1` envelope profiles.

This design replaces only the team-establishment portion of onboarding. It
supersedes the earlier remote-connect design assumptions that every pairing token is already
team-scoped, that exchange immediately returns an active credential binding,
and that the console or reference-server admin creates the team. The earlier design's
command shape, secret handling, status, doctor, disconnect/revoke, and key
handling remain in force unless this design says otherwise.

## Decision

We choose a **surgical rewrite of the onboarding state machine**, not an
additive `promote` endpoint on the current one-shot exchange and not a rewrite
of remote synchronization.

“Surgical” describes the subsystem boundary, not the amount of connect code
reused. The existing one-shot connect commit/pending path is replaced end to
end by the shared provisional/finalize path; Stage-1, Stage-2, envelope,
credential-storage, revoke, and binding-validation contracts are retained.

The one user action, `agmsg remote connect`, performs one of two strictly
separated operations:

- **Promote:** an existing local team, with a local identity catalog, becomes
  the canonical remote team. Its roster is created transactionally and its
  complete shareable local history is subsequently backfilled through Stage 1.
- **Join:** a clean local target pulls an existing remote team's immutable
  identity catalog, current roster revision, policy, and retained history. It
  does not create or merge a remote team.

Internally, connect uses the same two-call state machine as cloud CLI v6.
Exchange creates an onboarding session and single-delivers a short-lived
**provisional credential**. After the CLI durably stores that exact secret,
finalize atomically promotes or joins the team and changes that same credential
from provisional to active. Cloud v6's no-intent `activate` is the degenerate
case of this operation: **activate is a subset of finalize**, not a second state
machine. The user still runs one command.

The credential and team have deliberately different recovery semantics:

- the credential is a secret, delivered once and never fetched or reissued;
- the team, roster, and canonical result are resources, converging
  idempotently on `onboarding_id`.

There is no one-round-trip shortcut. Finalize MUST NOT occur until the exchange
response and provisional credential have been atomically written and fsynced.

### Cloud v6 crosswalk

| Cloud CLI v6 | Local-first onboarding |
| --- | --- |
| Provisional credential, delivered once | The same `provisional_credential` and credential slot |
| `POST /v1/device/activate` | Degenerate finalize with no team intent; no separate lifecycle |
| `POST /v1/onboarding/finalize` | Intent union adds promote/join resource body, then performs the same provisional-to-active transition |
| Secret recovery | Local durable credential slot only; never server re-fetch/reissue |
| Resource recovery | `onboarding_sessions(onboarding_id)` stored canonical result |
| Cloud operation observations | Reconciled projections of the server session, never an independent phase machine |

The shared field names, storage rigor, and single-delivery rules are inherited
from cloud v6. TTL is policy-specific while the lifecycle remains shared:
cloud's no-intent activate keeps its five-minute TTL; human promote/join
finalize uses a fixed 60-minute TTL. This design adds only the token-bound
tenant/policy context, promote/join body, local reservation, and
team/roster/backfill result.

## Local identity model

### Stable team and member IDs

Local team configuration becomes the source of stable identity instead of a
projection of server provisioning.

Every new local team gets a canonical UUIDv7 `team_id` when the local CLI first
creates it. Every member gets a canonical UUIDv7 `member_id` when the local CLI
first creates that member. IDs are generated once with a cryptographically
secure generator and are never regenerated on retry, rename, connect,
disconnect, storage compaction, or remote rebind.

An existing v1 local configuration is upgraded under the existing team-config
lock:

1. audit the complete selected store, including current configuration, event
   history, legacy message rows, read facts, and retired-name history, and
   produce an explicit identity-audit result;
2. resolve every active and historical principal to a durable member identity;
   unresolved names stop the migration for operator mapping or creation of an
   explicit retired member -- they are never inferred from opaque message
   projections;
3. generate and durably write one `team_id`;
4. generate and durably write one `member_id` for every resolved current or
   retired principal that does not already have a portable identity;
5. give every local registration stable `registration_id` and
   `installation_id` values; and
6. only then expose the upgraded identity document to onboarding.

The upgrade is one atomic config replacement. A crash before replacement
publishes no IDs; a crash after replacement reuses every published ID.

The v2 local shape separates the team member catalog from machine-local agent
placements:

```json
{
  "schema_version": 2,
  "name": "example-team",
  "team_id": "018f3f7e-0000-7000-8000-000000000001",
  "members_revision": null,
  "members": {
    "018f3f7e-0000-7000-8000-000000000010": {
      "name": "worker-1",
      "registrations": {
        "018f3f7e-0000-7000-8000-000000000011": {
          "installation_id": "018f3f7e-0000-7000-8000-000000000012",
          "type": "codex"
        }
      }
    }
  },
  "agents": {
    "worker-1": {
      "member_id": "018f3f7e-0000-7000-8000-000000000010",
      "placements": [
        {
          "registration_id": "018f3f7e-0000-7000-8000-000000000011",
          "project": "/machine-local/path"
        }
      ]
    }
  }
}
```

`members` is the portable identity catalog. It includes opaque canonical
registration and installation UUIDs plus the registration type because those
are already remote device identities in HTTP v1. `agents` contains only local
placements that refer to a portable registration. Machine-local project paths
never enter the remote roster. A clean joining device materializes the member
and remote registration catalogs but does not create an `agents` placement for
another machine.

`registration_id` identifies one portable logical agent registration;
`installation_id` is a portable opaque UUID identifying the installation that
owns it. Neither contains a hostname, path, or account name; UUIDv7's coarse
generation-time metadata remains visible as already documented by HTTP v1.
`type` is the bounded portable agent type.
Only `project` and placement lifecycle are machine-local. Registration
visibility, uniqueness, cardinality, retirement, and installation-sharing rules
are exactly those of HTTP v1; this design does not create a second device catalog.

The identity-audit ABI is strict JSON and returns the selected driver and
generation plus three bounded, canonically ordered sets:

- `active`: resolved `(normalized_name, member_id)` identities;
- `retired`: historical `(normalized_name, member_id)` identities required by
  messages or read facts; and
- `unresolved`: principals with evidence references that require explicit
  operator resolution.

Promotion is ineligible while `unresolved` is non-empty. The audit result and
the promotion snapshot descriptor are bound to the same driver generation.

`members_revision` is null until the first successful promote or join finalize.
Afterward it is the last server revision durably incorporated locally. Pending
local roster operations live in a separate durable outbox; they do not
speculatively increment the server revision.

Local registration lifecycle does not own the portable catalog. `leave` and
registration reset remove only the selected local placement/registration; even
the last local registration MUST NOT delete the members catalog, remote binding,
remote key state, identity history, or team configuration. Deleting the local
team is a separate explicit operation with binding-generation CAS and remote
recovery/revoke warnings.

### First creator is canonical

Within a team, a normalized member name is permanently anchored to the first
accepted `member_id`. The existing server identity-history tables enforce that
retired names and IDs cannot be rebound.

The local `join` command follows these rules:

- if the local member catalog already contains the normalized name, reuse that
  `member_id` and add only a new local registration;
- otherwise create a new `member_id` once and enqueue the roster mutation; and
- never infer identity from a message's opaque sender or recipient projection.

If a concurrent client creates the same normalized name under a different
`member_id`, the first server-accepted mutation is canonical. The loser stops
with an identity conflict. It MUST NOT silently rewrite message history or
alias the two members. The operator may rename an unaccepted local member and
retry. Deleting or rewriting a member that already owns local messages or read
facts requires a separate explicit repair design.

A rename retains `member_id` and enqueues a complete roster mutation. Local and
remote names may differ while that mutation is pending; Stage-2 read-state
publication for that member remains fail-closed until the authenticated roster
and local catalog agree, as required by the
[composite read-state frontier](../../adr/ref/0006-composite-read-state-frontier.md).

## Connect mode selection

Pairing tokens have one immutable purpose:

- a **promote token** is a single-use capability to create exactly one team on
  the server. It is bound at issuance to exactly one immutable `tenant_id`, the
  issuer account, a maximum allowed onboarding policy, and one reserved
  team-quota slot. It cannot select a tenant, modify an existing team, or create
  more than one team, and expires after 15 minutes;
- a **join token** is scoped to exactly one existing immutable team and one
  immutable tenant and authorizes one device join.

Token purpose, tenant, issuer, policy ceiling, quota reservation, and optional
team binding are copied into the server-side onboarding record and are not
client-selectable. Final activation derives all of them from that record. A
promote reservation is released exactly once on pre-activation expiry or
successful cancellation, and is consumed exactly once by successful team
creation. Finalized/activated records never release a consumed quota slot.
Concurrent expiry, cancellation, and activation serialize on the same row.
Thus a stolen promote token can create at most one initial roster and one
credential in its issuer-selected tenant.

A promote token also fixes the promotion resource budget:
`max_promotion_messages`, `max_promotion_bytes`, initial lease duration, and
absolute deadline, plus the Stage-2 exact-read limits. The reference defaults
are 1,000,000 messages, 5 GiB of decoded envelope bytes, 4,096 exact reads per
member, 65,536 per team, a 30-minute progress lease, and a 24-hour absolute
deadline; operators may configure lower values but never silently raise them
after exchange. Finalize rejects a declared snapshot or its precomputed
post-prefix exact-read count above any quota before creating the team.

The client sends its intended mode during exchange, and the token purpose MUST
match. A purpose mismatch is terminal and creates no session.

| Local target | Token purpose | Result |
| --- | --- | --- |
| Existing local team, no active binding | promote | Promote |
| No local team/config/store at target | join | Join and pull |
| Existing local team without an exact prior binding | join | Reject: both sides are populated |
| No local team/config/store | promote | Reject: there is no local authority to promote |

The local decision is made under a durable onboarding reservation, not by a
one-time filesystem precheck. Before the first network call, connect locks the
installation/team registry and atomically records:

- the intent and client onboarding ID;
- the normalized local team name;
- the selected absolute store identity and driver generation;
- the installation identity; and
- the observed absence or exact prior-binding generation.

All local team creation, join, send, store initialization, rename, and binding
replacement paths MUST honor that reservation. Final local materialization is a
compare-and-swap against the reservation generation and revalidates the target
store identity. If another process changes the target, connect does not
materialize or merge anything; it preserves the pending server recovery record
and cancels or revokes it when safe. Because the server cannot observe a local
filesystem, `both-sides-populated` is a local terminal result, never a server
error.

An exact-ID recovery of an interrupted prior promotion is a retry, not a merge.
A disconnected local team with a prior binding may reattach only when the join
token names that exact `server_instance_id` and `team_id`, the locally retained
member IDs descend from that binding, and the onboarding reservation names the
same local store identity and binding generation. Ordinary revision
reconciliation must find no identity conflict. This is lifecycle recovery
under the remote-connect lifecycle, not a third creation mode. A local team with no proof of that
prior tuple cannot use a join token merely because its display name or claimed
team ID matches.

For promote, an explicit local team is required unless the CLI can identify
exactly one eligible local team without prompting. Provider tooling MUST pass
the explicit team in non-interactive use. For join, the remote display name is
the default local name and the existing local-name override remains available.

## Onboarding protocol

### Phase 1: exchange a pairing token for a provisional credential

`POST /v1/onboarding/exchange` is the only endpoint that receives the opaque
pairing token. Its strict request becomes:

```json
{
  "token": "agmsg_pair_opaque",
  "onboarding_id": "550e8400-e29b-41d4-a716-446655440000",
  "intent": "promote"
}
```

`onboarding_id` is a client-generated UUIDv4, generated once and durably stored
with the local onboarding intent before network exposure. `intent` is
`promote` or `join`.

A successful exchange consumes the token and creates an
`onboarding_sessions` row plus a provisional credential, not an active team
credential. The response uses the cloud v6 core field names plus the
authenticated policy context needed before the E2EE choice:

```json
{
  "protocol_version": 1,
  "server_instance_id": "018f3f7e-0000-7000-8000-000000000000",
  "onboarding_session_id": "018f3f7e-0000-7000-8000-000000000020",
  "onboarding_id": "550e8400-e29b-41d4-a716-446655440000",
  "intent": "promote",
  "tenant_id": "018f3f7e-0000-7000-8000-000000000030",
  "credential_id": "018f3f7e-0000-7000-8000-000000000021",
  "provisional_credential": "agmsg_credential_opaque-value",
  "expires_at": "2026-07-24T07:00:00.000000Z",
  "onboarding_policy": {
    "accepted_envelope_versions": [1],
    "write_allowed_ciphers": ["none", "age-v1"],
    "policy_revision": "0",
    "effective_from_seq": "1",
    "max_blob_bytes": "1048576",
    "max_promotion_messages": "1000000",
    "max_promotion_bytes": "5368709120",
    "max_promotion_read_exacts_per_member": "4096",
    "max_promotion_read_exacts_per_team": "65536",
    "promotion_progress_lease_seconds": "1800",
    "promotion_absolute_deadline_seconds": "86400"
  }
}
```

`onboarding_id` is unique within issuer/origin scope. The exchange row lock
stores a domain-separated `exchange_request_digest` before returning. Reusing
the same ID with different input is a conflict. Reusing the same ID with
identical input returns only the same secret-free session status and
`409 provisional-credential-already-issued`; it never returns
`provisional_credential` a second time. A different onboarding ID cannot reuse
the consumed token.

For join, the strict response union also has `remote_team_id` and the complete
current capability/public-epoch snapshot; promote forbids that field because no
remote team exists yet. The authenticated response header and response bind the
`server_instance_id`, `onboarding_id`, intent, immutable tenant, token purpose,
policy ceiling, and optional join target.

`provisional_credential` is the future long-lived device secret, but
before finalize it authenticates exactly its own finalize operation. Status,
cancel, sync, roster mutation, message, member, read-state, and revoke endpoints
reject it as not active. The server stores only its domain-separated digest.
The promote/join provisional TTL is 60 minutes, evaluated on every request
rather than by sweeper timing; the exact timestamp is returned and clients do
not guess it. The longer TTL changes neither authority nor secret delivery: the
credential remains bound to
`(origin, server_instance_id, account, credential_id, onboarding_id)` and can
still perform only its own finalize. It cannot access a prior binding or any
ordinary operation. Request-time expiry and sweep/revoke use the same mechanism
as the five-minute no-intent credential; only the hard deadline differs.
Finalize evaluates expiry at the transaction's session-row validation point,
after waiting for the lock, so a request started before but validated after the
deadline cannot activate and implementations do not differ by HTTP arrival
timing.

The client writes the session ID, onboarding ID, purpose, credential ID,
provisional secret, origin, server instance, account, and exact exchange
response into the cloud-v6 provisional credential slot before it calls
finalize. The slot key is
`(origin, account, role="provisional", credential_id)`. It uses a `0700`
directory, `0600` file, atomic replacement, file and directory fsync,
`O_NOFOLLOW`, bounded strict parsing, and lock/CAS. Binding JSON remains
secret-free.

If the exchange response is lost before the client stores it, the short-lived
provisional credential expires and is revoked without creating a team or active
credential. No API re-delivers the secret. The own-operation status/cancel API
may prove and clean the abandoned operation, after which the operator issues a
new token. This failure creates neither an active device credential nor an
orphan team.

### Phase 2: idempotent finalize

The provisional credential authenticates:

```http
POST /v1/onboarding/finalize
Authorization: Bearer <provisional credential>
Agmsg-Protocol-Version: 1
Content-Type: application/json
```

The promote request contains the local identity document:

```json
{
  "onboarding_id": "550e8400-e29b-41d4-a716-446655440000",
  "intent": "promote",
  "body": {
    "local_team_id": "018f3f7e-0000-7000-8000-000000000001",
    "canonical_roster": {
      "team_name": "example-team",
      "members_revision": null,
      "members": [
        {
          "member_id": "018f3f7e-0000-7000-8000-000000000010",
          "name": "worker-1",
          "registrations": [
            {
              "registration_id": "018f3f7e-0000-7000-8000-000000000011",
              "installation_id": "018f3f7e-0000-7000-8000-000000000012",
              "type": "codex"
            }
          ]
        }
      ],
      "identity_history": []
    },
    "history_snapshot_metadata": {
      "mode": "all",
      "snapshot_id": "driver-defined-opaque-id",
      "driver_generation": "driver-defined-generation",
      "cutoff": "42",
      "message_count": "42",
      "source_message_digest": "sha256:base64url",
      "read_state_count": "7",
      "source_read_state_digest": "sha256:base64url",
      "translated_exact_count": "2",
      "estimated_bytes": "8192",
      "reserved_bytes": "16384",
      "source_snapshot_digest": "sha256:base64url"
    }
  }
}
```

The join request contains the onboarding ID, `intent: "join"`, and an empty
`body`. The join target comes exclusively from the token; the client cannot
substitute a tenant or team ID.

Finalize first resolves the credential and locks the onboarding session. After
binding and syntax validation, it looks up the stored canonical request digest
and result for `onboarding_id` **before** applying current expiry, cancellation,
policy, or revision checks. An exact completed retry returns the stored result;
a different digest is `409 onboarding-conflict`. A new request then validates
that the provisional credential is unexpired and uncancelled.

For a new request, one transaction:

- for promote, verifies that the team ID and normalized name are unused, creates
  the team in the token-bound tenant with the token's policy, consumes the
  reserved quota slot, applies the complete initial roster and permanent active
  and retired identity history, changes the provisional credential to active
  for that team, and marks the session finalized;
- for join, locks the token-selected existing team, activates the provisional
  credential for it, and marks the session finalized; and
- returns one binding, complete capability snapshot, complete roster snapshot,
  and resulting `members_revision` from the same team-row snapshot.

The server stores `(onboarding_session_id, onboarding_id,
exchange_request_digest, finalize_request_digest, resulting_team_id,
credential_id, finalized_at)`. The two digests use different domain/version
prefixes and are never compared interchangeably. An exact retry returns the
same canonical response. Reusing either ID with a different request is
`409 onboarding-conflict`.

The finalize body uses the 2 MiB control-request cap, the existing 1,000 active
member/team cap, and at most 4,096 permanent identity-history entries.
Registration limits remain those of HTTP v1. Identity audit rejects an
oversized catalog before exchange; promotion never truncates it. The server
stores the bounded canonical finalize result for the lifetime of the team so an
exact retry remains exact. After explicit team deletion, a permanent compact
tombstone retains onboarding/session/team/credential IDs and request/result
digests but no roster body.

The response uses the shared v6 shape:

```json
{
  "credential_id": "018f3f7e-0000-7000-8000-000000000021",
  "state": "active",
  "team_id": "018f3f7e-0000-7000-8000-000000000001",
  "canonical_roster": {},
  "capability": {}
}
```

The secret is not returned again because the client already durably holds it.
Finalize activates that exact digest; there is no second secret.

An unfinalized expired session cannot create a team and returns
`410 provisional-credential-expired`. A finalized session's resource result
remains available to its creator through own-operation status after the
provisional TTL, but no API re-delivers its secret.

Cancellation, finalization, expiry, and revocation have a strict precedence:

1. an exact finalized retry returns the stored resource result while its active
   credential remains valid;
2. finalization and pre-finalize cancellation are mutually exclusive row-lock
   transitions;
3. expiry or cancellation prevents a new finalize and releases an unconsumed
   quota reservation;
4. revocation of an active credential never rolls the session back, revives the
   secret, or deletes the created team;
5. after revocation, baseline own-operation status may prove the finalized
   `(tenant_id, team_id, credential_id, result_digest)`, but the client MUST
   quarantine local recovery material and MUST NOT commit a usable binding for
   the revoked secret; exact reattach requires a fresh join token bound to that
   same tuple.

`POST /v1/onboarding/status/{onboarding_id}/cancel` with a strict empty body
cancels only an unfinalized session and is idempotent. It is authorized only by
the issuer's narrow own-operation cleanup authority. Finalize/cancel races
serialize on the session row.

`GET /v1/onboarding/status/{onboarding_id}` returns one strict, secret-free
record containing `onboarding_session_id`, `onboarding_id`, `intent`,
`tenant_id`, `phase` (`provisional`, `finalized`, `cancelled`, or `expired`),
`credential_id`, `credential_state` (`provisional`, `active`, `revoked`, or
`expired`), `expires_at`, `team_id` or null, and `result_digest` or null. It is
authorized by the issuer's own-operation status authority, not by the
provisional secret. This server record is the single recovery truth.

Authorization permits an active, unrevoked credential to replay finalize only
for its own onboarding ID and exact stored request digest. It does not make
finalize a general active-credential mutation endpoint.

Hosted provider tooling calls status/cancel with its baseline
creator-bound own-operation authority. A bare OSS token holder has no such
account authority: if it lost the provisional secret it waits for request-time
expiry, while a self-host operator may inspect/cancel through the private admin
socket. UX and runbooks distinguish these paths and never promise a bare client
that it can query or cancel an operation it cannot authenticate.

The client validates the response binding, roster, revision, capabilities, and
onboarding IDs before atomically committing the local binding. A crash after
server commit but before local commit retries finalize and receives the same
result.

Onboarding responses use `Cache-Control: no-store`, strict UTF-8 JSON,
duplicate/unknown-field rejection, bounded bodies and headers, no redirects,
and the existing protocol-header rules. Access logs, APM, and traces MUST redact
pairing tokens, provisional credentials, and response bodies.

The minimum shared error contract is:

| HTTP | Code | Meaning and client action |
| --- | --- | --- |
| 401 | `invalid-pairing-token` | Unknown token; stop and request another |
| 401 | `invalid-onboarding-credential` | Pending secret is absent or invalid; stop |
| 409 | `pairing-token-consumed` | Token was already exchanged; recover a locally stored session or reissue after the old session expires |
| 409 | `provisional-credential-already-issued` | The same onboarding ID already received its one secret delivery; use the durable local slot or issuer status/cancel, never request the secret again |
| 403 | `onboarding-intent-conflict` | Token purpose and local mode differ; no automatic fallback |
| 403 | `onboarding-policy-violation` | Requested policy/epoch exceeds or relaxes the token-bound policy |
| 404 | `join-team-not-found` | The immutable token-scoped team is absent; stop |
| 409 | `onboarding-conflict` | An onboarding/session ID was reused with different canonical input; stop |
| 409 | `team-identity-conflict` | Promote collided with an existing team ID or normalized name; never adopt it implicitly |
| 410 | `pairing-token-expired` | Token expired before exchange; request another |
| 410 | `provisional-credential-expired` | Unfinalized provisional expired; prove cleanup, preserve audit, then request another |
| 410 | `onboarding-cancelled` | The unfinalized session was cancelled; never finalize it |
| 429 | `rate-limited` | Retry only after the authenticated response's bounded `Retry-After` |

Transport loss and retryable `5xx` preserve the existing exact-request retry
rules. Definitive `409` and `410` outcomes are not busy-retried.

`both-sides-populated` is a local terminal code emitted before exchange or by
the final local reservation CAS. It is not an HTTP error because the server
cannot attest to local cleanliness.

All UUID fields are lowercase canonical strings: client idempotency keys use
UUIDv4; team, member, registration, installation, session, and credential IDs
use UUIDv7 unless an existing referenced protocol fixes another opaque type.
Requests and stored digests use strict RFC 8785 JCS with a domain/version
prefix. JSON duplicate/unknown fields, lone surrogates, non-NFC identity text,
noncanonical decimal strings, and values outside the shared HTTP-v1 byte and
cardinality limits are rejected before mutation. Onboarding bodies are bounded
independently of message bodies; large history is represented by the bounded
snapshot/manifest protocol, never an unbounded finalize document.

### E2EE insertion point

The exchange response's onboarding policy is authenticated server input, not a
client trust anchor. Before promotion, the CLI must already have a
team-ID-scoped, append-only local minimum-security history and, for `age-v1`, a
retained epoch checkpoint established by explicit human or provider policy.
The effective write policy is the intersection of that local minimum and the
token/session policy. A `none`-only client facing an E2EE-required minimum
stops; it never treats a permissive or substituted server response as authority
to downgrade.

For promotion into an E2EE-required policy, connect completes the existing
generate/import/abort key flow before finalize and includes only the approved
public epoch snapshot or its pinned reference in the initial team document. The
snapshot binds at least `team_id`, `onboarding_id`, token-bound policy revision,
epoch revision/generation, and the retained previous digest. Between exchange
and finalize the client requires a full match of policy revision, capability
boundary, and public epoch digest; relaxation, substitution, or rollback is
terminal. Private age identities and plaintext stay local and never enter an
onboarding request, access log, trace, or error.

For join, finalize returns the current public epoch metadata. Until the joining
client establishes or imports the trusted epoch checkpoint, it may durably
download ciphertext but MUST keep it in `pending_key` quarantine and MUST NOT
project, display, or advance read state. Missing private key material never
weakens policy.

The exact epoch-authority wire document remains owned by the age-v1 profile; this
ADR does not invent a second key format or put key distribution in roster
state. The encrypt-once publication rule, anti-rollback checkpoint, epoch
cutover fence, and three-layer quarantine rules from the age-v1 profile remain
normative.

## Convergent roster API

`GET /v1/members` remains the canonical roster read. A new ordinary,
team-credential endpoint replaces privileged provisioning:

```http
PUT /v1/members
Authorization: Bearer <ordinary team credential>
Agmsg-Protocol-Version: 1
Agmsg-Team-ID: <immutable team UUIDv7>
Content-Type: application/json
```

```json
{
  "roster_mutation_id": "550e8400-e29b-41d4-a716-446655440001",
  "expected_members_revision": "7",
  "team_name": "example-team",
  "members": []
}
```

The request is a complete desired roster, uses all existing member,
registration, normalization, cardinality, and retirement rules, and carries no
machine-local path.

The server locks the team row and:

1. validates the binding, strict shape, canonical UUIDs, and canonical request
   digest;
2. looks up `roster_mutation_id` before revision comparison: the same digest
   returns its stored resulting revision, roster digest, and canonical snapshot
   even if later mutations have advanced the team; a different digest is
   `409 roster-mutation-conflict`;
3. only for a new mutation ID, compares `expected_members_revision`;
4. validates every immutable identity and permanent name/ID history rule;
5. atomically replaces the current roster and team display name;
6. increments the single shared `members_revision`; and
7. records the mutation ID, canonical request digest, resulting revision,
   complete canonical roster digest, and response snapshot.

Canonical mutation bytes are RFC 8785 JCS over a domain/version-separated
strict schema; canonical lowercase UUIDs, UTF-8 scalar/NFC rules, and protocol
cardinality/byte bounds apply before hashing. Team display-name changes share
the roster revision domain. An exact mutation retry returns the originally
stored result, not the current roster. A stale new mutation is
`409 members-revision-conflict` and includes the current revision and roster
digest; the client refetches `GET /v1/members` before any rebase.

There is no administrator credential tier in this protocol. Every active team
credential may submit a roster mutation. This makes credential compromise a
roster-integrity risk as well as a message/read-availability risk; documentation
and revocation UX MUST say so.

Member lifecycle and device credential lifecycle are independent. Retiring or
removing a member does not silently revoke credentials, and revoking a
credential does not delete or retire a member. Operators perform and audit
those mutations separately.

The local CLI remains the only product-facing team/member creation and mutation
surface. It updates the local identity catalog and a durable roster outbox in
one local transaction. The sync engine publishes the outbox through this API.
A revision conflict is never resolved by last-writer-wins. Disjoint changes may
be replayed on a freshly fetched roster; identity/name conflicts stop
fail-closed for explicit local resolution.

Each outbox entry stores the mutation ID, expected revision, complete canonical
desired roster, and digest before network exposure. Response loss retries the
same immutable entry. A successful stored result is incorporated locally before
the outbox entry is removed.

A stored retry result is an acknowledgement fact, not permission to roll the
local roster backward. Local application is monotonic:

- if local revision still equals the mutation's expected revision, apply the
  stored next snapshot with revision CAS;
- if local revision is already equal to or greater than the stored result,
  validate the stored mutation ID/digest/result binding and, when the current
  revision is not already authenticated, fetch `GET /v1/members`; then record
  the outbox acknowledgement and keep the newer local snapshot (a later
  mutation may legitimately have superseded the earlier effect); and
- never replace a higher local revision with an older stored response.

For a remote-bound team, a newly created member remains
`pending_remote_acceptance` until its roster mutation is accepted and the
canonical member ID is incorporated locally. A pending member cannot own an
active local registration, act/send, create read facts, or enter Stage-1/2.
Therefore a concurrent first-creator conflict cannot strand published
messages under the losing ID. Existing accepted members remain usable offline;
only new identity activation waits for server acceptance. Supporting offline
messages from unaccepted identities would require the separate explicit
identity-repair protocol rejected from v1.

## Sub-decisions

### A. Promote complete history, not a silent window

Promotion captures one durable storage-driver snapshot boundary and backfills
every shareable local message at or before that boundary. Messages created
after the boundary may be accepted into the local store and durably reserve an
envelope, but MUST NOT be posted or acknowledged ahead of the promotion
snapshot. The snapshot is an authoritative prefix of the binding's Stage-1
push stream. The CLI shows the message count and estimated bytes before
finalize; it does not silently choose a recent window.

The storage-driver promotion ABI returns exactly one strict
`promotion_snapshot` record:

```json
{
  "type": "promotion_snapshot",
  "snapshot_id": "driver-private-opaque-id",
  "store_identity": "driver-private-stable-id",
  "driver_generation": "driver-private-generation",
  "total_order_version": 1,
  "cutoff": "42",
  "message_count": "42",
  "source_message_digest": "sha256:base64url",
  "read_state_count": "7",
  "source_read_state_digest": "sha256:base64url",
  "translated_exact_count": "2",
  "estimated_bytes": "8192",
  "reserved_bytes": "16384",
  "source_snapshot_digest": "sha256:base64url"
}
```

The descriptor uses canonical bounded strings and nonnegative signed-BIGINT
decimals, rejects duplicate/unknown fields, and is immutable for the onboarding
ID. Separately domain-separated source message and read-state digests cover the
canonical ordered local message identities/payload digests and the exact/frontier
read work that must be preserved. `source_snapshot_digest` covers both
components, generation, cutoff, counts, reserved byte budget, translated exact
count, and total-order version.
`reserved_bytes` is a conservative upper bound derived from the selected
envelope profile and each source payload bound, not a best-effort estimate.
Finalize reserves this value; actual stored decoded envelope bytes must not
exceed it. `snapshot_id` is only an opaque correlation value; it is not accepted
as a security proof.

The bundled drivers define one deterministic promotion order spanning legacy
rows and the current event log. Stage-1's contiguous push cursor proves
completion through the snapshot cutoff. The engine may prepare later items, but
its POST selector enforces the cutoff barrier until every earlier promotion
position has a durable canonical acknowledgement. `remote status` keeps the
existing binding lifecycle `state` separate from a new `promotion`
object. A connected binding therefore remains `state: "active"` while
`promotion.phase` distinguishes:

- `promoting-roster`;
- `backfilling-history (acked/total)`;
- `complete`; and
- a terminal conflict or policy/key block.

The new team's message sequence is promotion-exclusive until
`backfill_complete`: promote creates it at `current_seq=0`, and only ordered
snapshot-prefix items may allocate sequences. The promoter's later local writes
can reserve but cannot POST. Join credentials created during
backfill are pull-only: message POST and Stage-2 read-state mutation return
`423 promotion-in-progress`, although local reads may accumulate durable facts
for later upload. Thus promotion positions map to one contiguous server
sequence prefix with no interleaved remote writer.

This fence is server-enforced, not merely an engine selector. While
`backfill_pending`, the ordinary message POST and ordinary Stage-2 mutation
endpoints return `423 promotion-in-progress` for **every** credential, including
the promoter. The only write exceptions are the manifest-first promotion
endpoints defined below. A raw client holding the ordinary credential cannot
insert a post-cutoff envelope into the prefix.

Under that fence, a contiguous local historical read prefix may translate to a
server frontier only after all covered promotion positions have durable
server-sequence mappings. Read facts beyond a hole translate to exact wire IDs.
The prefix is computed independently for each member over the promotion items
visible to that member: every covered item must have a durable read fact, and
the prefix stops at the first unread, quarantined, unmapped, or unresolved
identity item. A global local-position maximum is never treated as a member
frontier.
The driver computes the resulting per-member/team exact counts from the
immutable promotion order before finalize; counts above the token/capability
limits fail promotion before team creation. It MUST NOT silently widen a
frontier or drop exact facts. Join message/read writes become eligible only
after the server records `backfill_complete`.

Existing Stage-1 encrypt-once, ack reconciliation, and exact retry rules own the
actual upload. No onboarding endpoint accepts message bodies.

`connect` reports success once the binding and canonical roster are committed
locally and the durable history snapshot is queued; it does not hold a terminal
open until an arbitrarily large archive uploads. The ordinary polling engine
continues the backfill.

The server keeps a bounded `backfill_pending` lease under the team row from
promote finalize until completion. It accounts actual decoded envelope bytes
and distinct promotion messages against the token-reserved limits. The
30-minute lease renews only after committed, distinct newly stored message
bytes or newly validated read-state coverage; allowlist reservation alone and
exact page/message retries do not renew it. It can never pass the 24-hour
absolute deadline. As wire reservations become
durable, the client uploads two bounded, idempotent manifest streams:

- message allowlist entries
  `(promotion_position, wire_id, immutable_envelope_digest, decoded_size)`; and
- read-state entries, after durable mapping, as canonical
  `(member_id, kind=frontier, server_seq)` or
  `(member_id, kind=exact, wire_id)` facts.

```http
PUT /v1/onboarding/{onboarding_id}/backfill-manifest/{kind}/{page_index}
POST /v1/onboarding/{onboarding_id}/backfill/messages
POST /v1/onboarding/{onboarding_id}/backfill-complete
```

Each manifest page has at most 1,000 entries and is subject to the 2 MiB control
request cap. It contains the source snapshot digest, canonical decimal page
index and first position, ordered translated entries, and a domain-separated
page digest. Page indices and positions start at zero and are contiguous. An
exact page retry returns the stored page result; a different digest for an
existing index is a conflict.

Message allowlist pages MUST be registered before their envelope POST. The
dedicated promotion POST has a strict body:

```json
{
  "source_snapshot_digest": "sha256:base64url",
  "first_position": "0",
  "messages": [
    {
      "promotion_position": "0",
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "envelope": {
        "v": 1,
        "cipher": "none",
        "key_id": null,
        "blob": "base64"
      }
    }
  ]
}
```

Under the same team-row lock used by ordinary POST allocation, the server:

1. authenticates the exact promoter credential and onboarding/session;
2. validates the immutable source snapshot digest and current
   `backfill_pending` lease;
3. resolves every input position against the sealed allowlist and verifies wire
   ID, canonical envelope digest, decoded size, input order, and quota;
4. returns the stored original acknowledgement for an already fulfilled exact
   position, rejecting any payload mismatch;
5. requires every new item to begin at the next unfulfilled position and be a
   contiguous batch with no gap, unmanifested wire ID, or duplicate position;
6. performs the existing envelope policy/idempotency checks, allocates sequence
   numbers in position order, and atomically marks each allowlist entry
   fulfilled with its server sequence and actual byte count; and
7. commits acknowledgements in request order.

Because the team starts at sequence zero and all ordinary writes are fenced,
position `P` must receive server sequence `P+1`; any contrary stored state is
terminal corruption. A manifest-before-message crash leaves an unfulfilled
bounded allowlist entry. Message-before-manifest is impossible. Exact retry,
response-loss replay, echo reconciliation, and a retained tombstone converge on
the same position and original sequence.

Source and translated digests are deliberately different layers:

1. `source_message_digest`, `source_read_state_digest`, and
   `source_snapshot_digest` commit the pre-finalize local authority and never
   contain wire IDs or server sequences;
2. `translated_message_digest` and `translated_read_state_digest` commit the
   post-mapping manifests sent to the server; and
3. the driver-owned `mapping_proof_digest` commits a canonical ordered proof
   from each source item digest to its translated fact.

Message proof entries are
`(source_item_digest, promotion_position, wire_id, server_seq)`. Read proof
entries are
`(source_read_item_digest, translated_fact_digest, member_id, kind,
server_seq|wire_id)`; several source reads may intentionally map to one safe
frontier fact. Each layer has its own fixed domain/version prefix and ordering.
The strict driver proof result stores source/translated counts and all three
digest families and is immutable for the onboarding ID.

The completion request carries the source snapshot digest, cutoff, translated
message/read-state counts and digests, and mapping proof digest. Neither
endpoint accepts envelope blobs or plaintext.

The completion call succeeds only when:

- each sealed translated message/read-state manifest count and digest matches
  the completion request;
- every manifest wire ID exists as a live team message or permanent
  idempotency tombstone;
- the driver reports a durable local-ID-to-wire-ID/server-sequence mapping for
  every promoted message, with source count equal to the finalized source
  snapshot count and an acknowledged cutoff;
- every declared read exact has been promoted through that durable mapping, and
  the server's Stage-2 exact/frontier state covers every read-state manifest
  entry;
- the client reports the same immutable source snapshot descriptor, mapping
  proof digest, and contiguous acknowledged cutoff; and
- no manifest position is missing or duplicated.

The server can directly verify translated-manifest continuity, message/tombstone
existence, Stage-2 coverage, counts, and digests. It cannot independently know
the original local identities. The engine validates the detailed driver proof;
the server retains the source, translated, and mapping-proof digests in the
canonical promotion result/status so exact retries cannot substitute another
translation. A source digest is never compared to or reused as a translated
manifest digest.

The read-state manifest endpoint is the only Stage-2 write exception during
promotion. It applies a page only after every referenced message mapping is
fulfilled and validates the safe frontier/exact rules; ordinary Stage-2 writes
from promoter and joiners remain fenced until `backfill_complete`.

Message mapping, local exact-read alias promotion, and the read-state outbox are
one local transaction before a read manifest entry becomes uploadable. A
blocking quarantine row is never considered projected/read merely because a
remote frontier covers its sequence. Backfill completion therefore proves both
message availability and the read facts promised by the snapshot; message
retention or Stage-2 GC cannot run between those proofs.

The team-row transaction records `backfill_complete` and releases the
team-wide promotion barrier atomically. A second device may join while backfill
is pending. Join finalize creates a bounded, credential-scoped
`initial_sync_lease` containing a random lease ID, the authenticated retention
floor, backfill generation, current sequence, and expiry. When backfill later
completes, the lease acquires the manifest's terminal server sequence. The
joiner periodically posts its durable transport cursor to
`POST /v1/onboarding/initial-sync/{lease_id}/ack`; the server releases that
lease only after the cursor covers the terminal sequence.

Retention uses the minimum floor protected by any unexpired initial-sync lease,
even after the team-wide promotion barrier is released. The reference
initial-sync lease is 24 hours and is not silently renewed without durable pull
progress. Its status is `pending`, `complete`, or `expired-incomplete`. An
expired join that did not acknowledge the terminal sequence MUST report that
complete history is no longer guaranteed and may receive the ordinary 410
resync-required outcome; it never labels itself complete.

Join issuance is bounded independently from promotion: the reference limits are
60 join tokens/hour/team, 128 active initial-sync leases/team, and 10,000/tenant,
with lower operator overrides allowed. Hitting a cap rejects only the new join;
it never evicts an existing lease. Revoking the credential that owns an
incomplete lease releases that lease under the team-row lock. Progress may not
extend any lease beyond its original 24-hour absolute expiry.

The bundled SQLite promotion path MUST include pre-event-log legacy rows rather
than silently leave them local-only. It may materialize a durable,
driver-private promotion queue, but it MUST preserve stable local identity,
recipient read facts, and a deterministic total order without duplicating
local inbox/history projection. A driver that cannot prove a complete stable
snapshot fails promotion before finalize.

Server retention is suspended at the promote-time floor while
`backfill_pending`. Retention, lease renewal/expiry, manifest completion,
initial-sync acknowledgement, tombstone creation, delivery deletion, floor
advancement, and Stage-2 exact/frontier GC serialize on the same team-row lock.
After completion, retention still honors initial-sync lease floors.

If message/byte quota, progress lease, or absolute deadline is exceeded, one
team-row transaction marks `promotion_failed`, rejects further message writes
with a terminal promotion error, releases the promotion retention barrier, and
marks all associated initial-sync leases
`failed-incomplete-protected-until-expiry`. Configured retention may resume,
but continues honoring their floors until each original lease expiry; only then
does its phase become `expired-incomplete` and its floor become unprotected.
The team can never claim complete or issue new join tokens in that state. The
operator runbook revokes the credential and explicitly aborts/repairs the
incomplete team; expiry alone never converts partial history into success.
Metrics warn on quota, stalled progress, lease expiry, and retained bytes. A
future explicit history-window product is a separate interface and policy
decision.

### B. Make every externally visible transition retryable

The required crash outcomes are:

| Failure point | Durable result |
| --- | --- |
| Before local identity upgrade commit | No published new IDs |
| After identity upgrade commit | Exact IDs reused |
| Before exchange response is stored | Expiring provisional only; no team or active credential; secret is never reissued |
| After provisional slot store, before finalize | Retry exact finalize with the stored secret |
| After finalize commit, before response/local binding commit | Retry returns identical binding and roster |
| During local binding commit | Server canonical result remains recoverable by onboarding ID; local projection remains pending |
| Finalize/cancel race | Row-lock winner is terminal; loser observes the stored outcome |
| Credential revoked after finalize but before local commit | Status proves the resource result, local secret is quarantined, and no usable binding is committed |
| During history seal/reserve | Existing Stage-1 pre-publication abandon or exact-envelope reuse |
| After message POST, before ack reconcile | Exact wire/envelope replay and canonical ack |

Cloud `onboarding_sessions(onboarding_id)` is the sole authority for phase and
resource result. The local onboarding reservation, provisional credential file,
and pending binding are durable projections; none independently advances the
server phase. `remote status --json` correlates them by `onboarding_id` and
reports discrepancies, but it never elects a local projection as truth.

For this flow, the earlier token-hash-derived pending implementation is replaced,
not treated as the new authority. The public pending-management ABI keeps an
opaque `pending_id`, but its internal key is
`(onboarding_id, onboarding_session_id, reservation_generation)`. Legacy
token-hash pending records are quarantine/cleanup material and are never
auto-promoted. The connect write-pending, commit, abort, and CAS recheck paths
are rewritten around the shared session and cloud-v6 provisional-credential
slot.

The strict machine-readable status ABI becomes schema version 2:

```json
{
  "schema_version": 2,
  "local_team": "example-team",
  "endpoint": "https://example.invalid",
  "server_instance_id": "018f3f7e-0000-7000-8000-000000000000",
  "remote_team_id": null,
  "credential_id": "018f3f7e-0000-7000-8000-000000000021",
  "state": "onboarding",
  "onboarding": {
    "onboarding_id": "550e8400-e29b-41d4-a716-446655440000",
    "intent": "promote",
    "pending_id": "opaque-local-handle",
    "server_phase": "provisional",
    "server_result_digest": null,
    "server_observed_at": "2026-07-24T06:10:00.000000Z",
    "server_observation": "authenticated-current",
    "local_projection": "provisional-stored"
  },
  "promotion": null,
  "initial_sync": null
}
```

`state` is `onboarding`, `active`, or `disconnected`. `onboarding` is required
only for `onboarding` and reports the last authenticated server observation
alongside the local projection; it never mutates or overrides the server
session. Offline output sets `server_observation: "stale-offline"` and retains
the original `server_observed_at` and result digest; it never presents cached
phase as current truth. An active local state can be established only by a
full match to the server's finalized result followed by successful local
reservation CAS. An active binding requires null `onboarding` and has
`promotion` set to null or `{phase, acked, total, blocked_reason}` with phase
`promoting-roster`, `backfilling-history`, `complete`, `blocked`, or `failed`.
For a joining binding, `initial_sync` is
`{lease_id, phase, pinned_floor, terminal_server_seq, transport_cursor,
expires_at}` with phase `pending`, `complete`, or `expired-incomplete`;
promotion failure may first set
`failed-incomplete-protected-until-expiry`. Otherwise it is null. Canonical
decimal and strict-null rules are pinned in the driver interface.

Pending onboarding state is never deleted merely because it is old or
malformed. It is quarantined as private recovery material until server-proven
cancellation, successful finalize plus local commit, or explicit operator
cleanup after credential/team inventory. The server never stores recoverable
secret plaintext; the client never invents a resource result.

### C. A clean second device adopts canonical member IDs

The canonical second-device flow assumes that the `/agmsg` skill's `not_joined` branch offers `remote connect` as a first-class choice.

A join finalize requires a still-valid clean-target onboarding reservation.
The local commit atomically materializes the remote `team_id`, team name,
`members_revision`, complete active/retired member catalog, remote binding, and
reservation completion marker before enabling sync. It then pulls from the
authenticated retention floor.

The pull does not create local agent placements. When the user later runs the
local join/act-as flow with an existing normalized member name, the CLI reuses
the pulled canonical `member_id` and creates only a new registration. It MUST
NOT mint a second member ID for that name.

If any local team config, local history, independent member catalog, non-empty
target store, changed driver generation, or competing reservation exists, join
refuses locally before exchange or at its final local CAS. V1 does not compare
and merge both sides. This restriction is what makes automatic adoption safe.

### D. Demote raw server operations to escape hatches

The primary self-host quickstart no longer contains `team create`,
`provision.js`, a roster JSON file, or `psql`.

Self-host and hosted management surfaces issue only:

- a one-team promote token for the first local authority; or
- a team-scoped join token for a clean additional device.

The reference admin `token issue` command may remain as the self-host token
delivery mechanism, but promote-token issuance takes no team name or roster and
cannot itself create a team.

Self-host token issuance is authorized by an explicitly local operator
boundary: a Unix-domain admin socket restricted to the server OS account, or an
offline root/admin secret read from a private file or fd. It is never exposed
as an unauthenticated public HTTP route. Issuance binds tenant, issuer,
purpose, policy ceiling, and quota reservation, writes an audit record, and
prints the raw token exactly once to stdout. Hosted issuance uses the
authenticated account/tenant control plane but produces the same token
contract.

`provision.js` becomes an explicitly low-level client of the same
`PUT /v1/members` endpoint. It requires an ordinary team credential,
`expected_members_revision`, and `roster_mutation_id`; it receives no privileged
database path. It is suitable for scripted repair or bulk input, not onboarding.

Direct SQL is an unsupported offline recovery escape hatch. It is not a
protocol authority and cannot safely bypass identity history, revision,
mutation-id, or read-state invariants. Reference documentation removes it from
normal setup and warns that the server must be stopped and invariants audited
before any emergency database repair.

## Driver and local-commit ABIs

Implementation requires three explicit seams; none may be replaced by the
engine reading a bundled driver's private database or by the CLI inferring
state from files it does not own.

### Identity audit

`storage_sync_identity_audit` takes the selected local team/store identity and
returns the strict active/retired/unresolved result defined in the local
identity section. It is read-only, snapshot-bound, canonical, and side-effect
free. `storage_sync_identity_apply` may publish an operator-approved resolution,
but only under generation CAS and in the same transaction as the v2 identity
catalog migration.

### Promotion snapshot

`storage_sync_promotion_snapshot` creates or returns the immutable snapshot
descriptor defined in sub-decision A. Reentry for the same onboarding ID and
input returns the same descriptor. A different input is a conflict. The
driver's prepare selector exposes promotion position and enforces the cutoff
barrier without changing the existing exact-envelope retry contract.

### Local onboarding reservation and commit

The CLI-owned `local_onboarding_reserve/status/commit/abort` seam stores a
strict record:

```json
{
  "onboarding_id": "550e8400-e29b-41d4-a716-446655440000",
  "intent": "join",
  "installation_id": "018f3f7e-0000-7000-8000-000000000012",
  "local_team_name": "example-team",
  "target_locator": {
    "driver": "sqlite",
    "canonical_path": "/absolute/private/team-store"
  },
  "observed_store_identity": null,
  "observed_generation": null,
  "prior_binding_digest": null,
  "reservation_generation": "1"
}
```

The record is versioned, byte-bounded, duplicate/unknown-field rejecting, and
stored under the same lock respected by every local team/store mutation path.
`commit` is a generation CAS that revalidates the target before atomically
publishing a binding or clean join. `abort` never deletes provisional secret or
pending recovery material without server cancellation/revocation proof.
For an absent clean-join store, `target_locator` exists while
`observed_store_identity` and generation are null. Creation uses no-follow
opens, validates the parent directory identity/ownership/mode captured by the
reservation, and atomically publishes the new store identity under the same
CAS.

The shared fixture suite includes a bundled legacy SQLite store with current
writes racing snapshot capture, a retired historical member, read facts, and a
clean target racing local initialization. Both track implementations consume
the same fixtures and strict schemas.

## Ownership boundary

The implementation is split by contract, not by file convenience.

### Server/sync track (aggie-co2)

- HTTP/spec changes for onboarding exchange/finalize and roster mutation;
- `onboarding_sessions`, provisional-to-active credential transition, mutation
  dedupe, team/roster transaction, and capability snapshot;
- reference-server token purposes and admin/quickstart demotion;
- sync-engine promotion snapshot/backfill orchestration and status;
- `storage_sync_identity_audit` and
  `storage_sync_promotion_snapshot`, including legacy SQLite history; and
- protocol/integration tests for crash, response loss, concurrency, identity
  conflicts, and full backfill.

### Local CLI track (aggie-cc2)

- local config v2 and atomic UUID migration;
- `join`/`team` member catalog versus local registration behavior;
- `remote connect` local-exists/clean-target detection and intent selection;
- `local_onboarding_reserve/status/commit/abort`, cloud-v6 provisional
  credential slot integration, exact finalize retry, and local binding commit;
- clean-device roster materialization and same-name member-ID reuse; and
- human UX for promote progress, join refusal, conflicts, and recovery.

Both tracks consume the exact JSON schemas and error matrix pinned by the HTTP
spec. Neither track may independently reinterpret a field or add a fallback
merge.

## Compatibility and rollout

This is a pre-release dogfood stack, so the protocol does not preserve the old
server-first onboarding flow.

- Existing active dogfood bindings remain usable for sync while the new flow is
  developed.
- New onboarding uses only the shared cloud-v6
  exchange/provisional/finalize protocol after cutover.
- There is no automatic conversion of an old consumed pairing token.
- Draft servers may offer a temporary feature flag for tests, but published v1
  documents one canonical local-first flow.
- the remote-connect design points its superseded creation/exchange sections here;
  its unaffected security and UX requirements remain normative.

## Rejected alternatives

- **Add promotion after the current one-shot exchange.** Rejected because the
  current exchange requires an existing team and creates an active credential.
  Weakening those constraints would leave credential activation, team creation,
  and response-loss recovery split across incompatible transactions.
- **Rewrite the full remote stack.** Rejected because synchronization,
  credential secrecy/revocation, binding validation, E2EE, and cursor layers are
  independent of who creates the first team and have already survived
  adversarial review.
- **Keep server-first team creation as a self-host exception.** Rejected because
  it creates two product stories and makes E2EE/local-first behavior appear to
  be a hosted-only downgrade.
- **Infer promote versus join from server name lookup.** Rejected because names
  are mutable display values, leak existence, and cannot authorize creation or
  joining. Token purpose and local state decide the mode.
- **Merge two populated teams automatically.** Rejected for v1. There is no safe
  automatic answer for duplicate semantic messages with different wire IDs,
  same-name members with different IDs, divergent read facts, or independent
  E2EE epochs.
- **Upload only a recent history window by default.** Rejected because it makes
  the second device silently incomplete and turns retention/product policy into
  an irreversible client-side omission.
- **Keep `provision.js` or SQL as a privileged roster authority.** Rejected
  because it bypasses the same convergence and concurrency rules every local
  client must obey.

## Consequences

- Positive: the only team-creation story starts locally and uses the same CLI
  for hosted and self-hosted deployments.
- Positive: immutable member IDs exist before messages are promoted, so roster,
  read state, and future device registration share one identity anchor.
- Positive: secret response loss leaves only an expiring provisional, while
  resource response loss converges to the same team and roster; no secret is
  reissued.
- Positive: current Stage-1, Stage-2, and E2EE work remains the transport and
  confidentiality foundation.
- Negative: local team configuration needs a versioned identity migration and a
  member-catalog/registration split.
- Negative: onboarding requires a new session/provisional state and an
  incompatible pairing exchange response.
- Negative: full legacy-history promotion requires additional bundled-driver
  work before existing SQLite installations are genuinely supported.
- Negative: ordinary device credentials can mutate the roster, increasing the
  impact of credential compromise.
- Neutral: cloud consoles and self-host admin tools still issue access tokens
  and show/manage device credentials, but they no longer create product teams
  or author rosters.

## Implementation gates

Implementation does not begin until adversarial review closes at least:

1. shared cloud-v6 exchange/provisional/finalize response-loss, expiry,
   cancellation, revocation, and concurrent retry;
2. tenant/issuer/policy/quota-bound promote-token authority and inability to
   modify existing teams;
3. join-token team binding plus local reservation/CAS clean-target proof;
4. complete active/retired identity audit and initial roster, team, quota, and
   credential activation in one team transaction;
5. roster mutation stored-result-before-revision ordering, revision races,
   name/ID conflicts, outbox retry, and retirement;
6. atomic local UUID migration, registration/member separation, and same-name
   canonical adoption;
7. full event-log plus legacy SQLite promotion snapshot, strict cutoff ordering,
   manifest proof, retention barrier, and server `backfill_complete`;
8. E2EE-required promote/join with local minimum policy, anti-rollback
   checkpoint, and no private-key or plaintext leakage;
9. strict identity-audit, promotion-snapshot, and local-reservation ABI fixtures;
10. every new SQL interpolation point uses the shared strict parameterization
    and escaping seam established by the storage hardening work;
11. no team/message/member creation from opaque message contents; and
12. removal of server-first/raw provisioning from the primary quickstart.

Required adversarial fixtures include: a finalize just before/at/after the
60-minute expiry; a slow join that has not reached the backfill terminal
sequence when team completion occurs; an abandoned promotion hitting progress,
byte, and hard-deadline limits; an exact legacy read fact whose mapping is
created after message upload; a roster response-loss retry after local revision
has already advanced; and a losing unaccepted same-name member attempting to
act/send/read. Manifest fixtures independently mutate source, translated, and
mapping-proof digests. Backfill fixtures attempt interleaved joiner message/read
writes and exceed per-member/team exact-read caps; all must fail before an
unsafe frontier or silent omission is published. Server-gate fixtures attempt a
promoter ordinary POST, message-before-manifest, manifest position gap,
post-cutoff wire ID, response-loss retry, and envelope-digest mismatch.

## References

- [ADR 0005: Remote synchronization contract](../../adr/ref/0005-remote-sync-contract.md)
- [ADR 0006: Composite read-state frontier](../../adr/ref/0006-composite-read-state-frontier.md)
- [ADR 0007: Stable member and roster identity](../../adr/ref/0007-stable-member-and-roster-identity.md)
- [Remote connect onboarding design](remote-connect-onboarding.md)
- [Stage-1 remote synchronization](../../spec/ref/stage-1-remote-sync.md)
- [Cipher-independent opaque-envelope server schema](../../spec/ref/server-opaque-envelope.md)
- [Stage-2 read-state synchronization](../../spec/ref/read-state-synchronization.md)
- [HTTP API v1](../../../server/spec/v1.md)
