# Device pairing (`key request` / `key approve`)

> **SUPERSEDED.** The onboarding this describes was replaced by
> [`docs/design/remote-sync.md`](../remote-sync.md), which states the replacement
> from its own side. Kept as design history: the reasoning here is why the
> current shape is what it is, and the findings it records were closed rather
> than dropped. Do not build to it.

**Status: draft, revision 7.** Replaces the key-pairing work that the remote
connect onboarding design had held back as NOT READY. One-directional
authentication was closed by the onboarding pivot's post-decryption
bidirectional SAS. Revision 1 was returned CHANGES REQUIRED with eight blockers
(B1-B8), alongside eight further gaps from the mobile client. Revision 2
rebuilt the document around observability and closed B1 and the frame,
freeze-order, rate-limit-identity, non-addressee-validation, rollback-baseline
and classification findings; it was returned with six more (R1-R6), all of
them exact state or wire semantics, which revision 3 addressed. Revision 3
was returned with two blockers. **T1**: the state table named states but never
said what each one *leaves via*, and neither the TTL nor abort was scoped to
the states it may act on. **T2**: the `completed` acknowledgement had no
durable owner, so a device that crashed between promoting the key and
acknowledging it left device 1 waiting on a state that would never arrive.
Revision 4 closed both on the server, and was returned with two more (U1, U2)
showing that each had been left open on the *client*. **U1**: scoping the TTL
server-side did not stop the local deadline handler from erasing staged
material while a consume was in flight, which re-opened the exact race T1
existed to close. **U2**: `activation_failed` was made mandatory for a failure
mode — reinstall, keystore loss — that destroys the credential and journal
needed to send it, so the transition was unexecutable in the case that
motivated it. Revision 5 closed both, adding one new state, and was returned
with three more (V1-V3) — all in the machinery revision 5 had just introduced.
**V1**: the staged-material retention bound erased on an unknown outcome and
then assumed a transition that may not be legal, while inviting the implementer
to erase the very journal needed to report anything. **V2**: making `abandoned`
terminal discarded a late but genuine completion from a device that came
back — throwing away an authenticated fact the design had just finished
arguing must never be thrown away. **V3**: the completion deadline gating
`abandoned` was never connected to the state or status contract, so it had no
origin, no binding, and nothing stopping a server from moving it. Revision 6
closed those three and was returned with three more (W1-W3), all in the
late-evidence machinery it had just added. **W1**: revision 5's definition of
`abandoned` was still present further down, contradicting revision 6's own
replacement of it in the same document. **W2**: appending evidence was
indistinguishable from a server mutating a terminal request under the status
contract's version rule. **W3**: the late acknowledgement was described as
append-only without being tied to the operation ledger, so every lost response
could add another row.

Pairing is the **primary path for a second device**; the recovery key is the
disaster path for when no live machine remains. Pairing is OSS because it is
closed within one team.

## What revision 1 got structurally wrong

Every reviewer landed on the same defect from a different side. Revision 1
described the **authoritative state on the server** and never described **how
each device observes that state**. Consequently:

- `aborted` existed as a state with no way for the other device to learn it,
  so a device-1 refusal showed up on device 2 fifteen minutes later as
  "expired" — a false statement to the human, not merely a missing string.
- `approved` was observable only by the arrival of the payload itself, so
  "approved, delivery in flight" and "not approved yet" were indistinguishable
  — and they call for opposite human actions.
- Decryption failure on a request addressed to *this* device was unnamed, so
  the most likely outcome of an actual substitution attack had no state.
- The durability ordering between the server's `consumed` and the device's
  local key commit was undefined, so a crash could leave the two disagreeing
  in either direction.

So this revision is organised around **observability first**: every
transition states who owns the authority, how each side learns of it, how
that observation is authenticated and kept fresh, how it is re-obtained after
a loss, and what happens when it cannot be obtained at all. States that no
one can observe are not states.

## Classification

The decision **"pairing key delivery never uses the team-message cipher
profile, and never rides ordinary message admission"** is hard to reverse and
belongs in the consolidated remote synchronization contract ADR as a negative
decision, not in a new ADR of its own. The literal `pair-v1` identifier, its
frame, the state machine, and the TTL belong in a **versioned spec under
`docs/spec/`** once this design settles. This document is the pre-
implementation study, and is expected to be superseded by that spec rather
than to survive as the normative text.

## E1 — pairing cannot use `age-v1`, and cannot constrain it either

`age-v1` forbids this payload three times over: `cipher` is fixed and admits
no content negotiation; `key_id` names one immutable recipient-set epoch; and
a writer must encrypt to every recipient of the selected manifest and to no
real recipient outside it, with the reader required to find its own recipient
in that manifest. A pairing blob is encrypted to a one-time recipient that
must never enter a manifest. The profile's own rule — an incompatible change
requires a new identifier — gives the answer: a separate `pair-v1` profile,
with `age-v1` untouched and no `age-v2`.

**Revision 1 then contradicted itself** by reserving the `pair-` prefix in the
`key_id` grammar. `age-v1`'s `key_id` is `[a-z0-9][a-z0-9._-]{0,63}` and does
not exclude `pair-*`, so an existing legitimate epoch may already use it.
Reserving it retroactively *is* a change to `age-v1`, which the same paragraph
promised not to make, and would additionally require a state scan and a
versioned contract change.

**Dispatch is therefore on the outer `cipher` first, then `key_id` within that
profile.** `(cipher, key_id)` is the key; `key_id` shape rules apply only
inside `pair-v1`. No prefix is reserved in any other profile's label space.

## Delivery admission

A `pair-v1` envelope **must not be accepted through ordinary message POST.**
Allowing it there would let any ordinary writer bypass the team's effective
cipher policy and inject arbitrary blobs, while leaving the existing
validators unchanged would reject it outright — the draft assumed both at
once.

Delivery is a **dedicated authenticated pairing-delivery operation** that
verifies team, request, approver credential, request state and version, and
the frozen recipient digest, admits exactly one delivery per request, and
performs the request CAS and the control-row append **in one transaction**.

The abort notice, the `completed` acknowledgement, the `activation_failed`
report and the `abandoned` declaration are separate operations of the **same
dedicated, authenticated family**:
each verifies the credential, re-checks the request state and version inside
the lock, and performs its CAS together with any control-row append in one
transaction. None of them is reachable through ordinary message POST either.

Its effects on every stream-level quantity are pinned here rather than
inherited. "Must not leave a hole" was not a specification — it left each
implementer to invent a different frontier.

- The control append **consumes exactly one `server_seq`** and **appears in
  the pull transport cursor**, like any other row.
- It is **excluded from** the ordinary message count, the unread count, agent
  projection, and the user read manifest.
- The **read frontier may cross the control seq as automatically processed**,
  and must not fabricate a user-read fact for it.
- **Retention and resync treat it identically to an ordinary row**, keeping
  the same identity across both.
- The **approver's own echo is exact replay** and is not re-emitted.

Which record kind of the existing Stage 1/2 ABI carries this is a contract
point to settle with the storage/server owner before implementation; it is
not a free choice for this document to make.

## The `pair-v1` envelope and frame

```json
{ "v": 1, "cipher": "pair-v1", "key_id": "<request_id>", "blob": "<base64 age file>" }
```

The blob is produced by age's native X25519 recipient encryption — the
"zero new cryptography" constraint holds; what is new is the envelope and the
frame, not the primitive.

**The frame is `pair-v1`'s own, not `age-v1`'s.** Revision 1 said the two
share their base64/age-file encoding and implied the rest carried over;
`age-v1`'s validator also binds `wire_id`, team, cipher, `key_id` and the
message JCS, none of which apply here. The correct split is a **shared outer
age parser** plus a **profile-specific frame and policy validator**.

`pair-v1`'s authenticated bytes bind, uniquely and reconstructibly from the
outer values, with constant-time comparison:

protocol version; `server_instance_id`; `team_id`; the **client-generated
control `wire_id`**; `request_id`; the outer `cipher` and `key_id`; the
**frozen recipient public key**; the **approver nonce**; the delivered
epoch's `key_id`, `epoch_revision` and snapshot digest; and the delivered
bundle digest.

**`server_seq` is deliberately not bound.** Sealing happens once, before the
envelope is offered to the server, while `server_seq` is assigned in the
append transaction — a sealed ciphertext cannot bind a number that does not
exist yet. Binding the client-generated `wire_id` instead is the same shape
`age-v1` already uses. Pre-reserving a sequence number to make it bindable
would introduce another state and another crash contract for no gain.

**Validation reuses `age-v1`'s hardening rather than relaxing it:** exactly
one real X25519 stanza (GREASE excluded from that count), the same strict
Rust GREASE subset already pinned for `age-v1`, the same total/header/line
bounds, and `scrypt`, SSH, `plugin-` and every other active stanza type
rejected before the decryptor is invoked.

## A1 — the confirmation code, and the ordering that makes a short SAS sound

The original code was derived from the temporary public key's fingerprint,
which is precisely what a substituting server can grind offline. The redesign
separates the two jobs that construction conflated.

**The request code is not an authenticator.** It is a selector plus the
human's authorization gesture, generated as a **random value by the requesting
device** and derived from no key material, so nothing about the keys can be
ground to collide with it. Its grammar is strict and fixed, collisions are
retried at generation, and it is never written to logs or telemetry — it is
not a bearer secret (which is why passing it as `approve`'s argument does not
violate the argv prohibition), but there is no reason to retain it either.

**Authentication lives in the SAS**, derived from the frame's authenticated
bytes and displayed by both devices for the human to compare. It binds **the
recipient public key each side actually used**, which is what makes
substitution visible: a server that swapped in its own recipient sees one
value, the requester derives another, and re-sealing to the real requester
does not repair the difference.

**The approver nonce removes the offline grind only if the ordering is
normative**, which revision 1 asserted rather than required. A server CAS is
not proof that the recipient was fixed before the nonce existed. The approving
device therefore MUST:

1. resolve the code, obtaining the recipient bytes together with the request
   id and version, and **freeze them locally**;
2. only then generate the nonce;
3. never re-fetch the recipient, sealing to the frozen snapshot;
4. not reveal the nonce to the server before the sealed request.

The CAS re-checks the frozen recipient digest and the request version.
**Sealing happens once**: a retry re-sends the exact bytes from a durable
outbox and never regenerates the nonce, the key, or the envelope, because
regeneration would produce two different SASes for one request whenever a
response is lost.

An outbox is only half of that, though — it also needs matching replay
semantics on the server, or a lost response turns into a permanent failure.

Before anything touches the network, the approver durably records
`(operation_id, request id and version, frozen recipient digest, control
wire_id, exact envelope digest and bytes)` atomically. The server performs
`pending → approved`, the control append, and the storage of its result **in
one transaction**. A retry carrying the same `operation_id` and request
digest returns the **stored acknowledgement**, including after the request is
already `approved`; if any of those fields differs it fails closed with a
conflict rather than producing a second delivery. Without this, the ordinary
response-loss retry would observe `approved` and report failure for a
delivery that in fact succeeded.

**A second local invocation resolving the same code resumes the existing
outbox entry, or is refused single-flight** — it never starts a fresh
resolve. Only the approver holding the winning delivery acknowledgement
displays a SAS. This is what actually closes the "resolve twice and swap the
frozen snapshot" hole; freezing alone did not.

Length, alphabet, and **grouping** of both strings are fixed as numbers in
the versioned spec, together with the attempt rates they depend on (see
"Before implementation"). Grouping is protocol-level, not per-client: humans
compare two strings far more accurately when the separation is identical on
both screens, so a CLI and a mobile client must not choose it independently.
The code and the SAS must also be visually distinguishable from each other.

## Rate limiting

A pending cap alone is not an online-guessing bound — an attacker can spend a
whole TTL guessing against the same pending set. Approval requires an
**authenticated approver credential**, with bounded attempt rates per account,
team, credential and address, and a global circuit breaker. `expired` and
`not-found` are distinguished **only after authentication**, and the response
carries no other metadata.

The per-machine cap counts against a **stable installation identity the server
derives from the credential**, never a self-reported name, address or
temporary key, and is ANDed with the per-team and per-account caps because
credentials churn. Reaching a cap refuses new requests rather than evicting
old ones, so flooding cannot flush a legitimate pending request.

## State, authority, and observation

| state | meaning | authority | leaves via |
|---|---|---|---|
| `pending` | registered, awaiting approval | server | `approved`, `aborted`, `expired` |
| `approved` | approval reserved, delivery admitted | server | `consumed`, `aborted`, `expired` |
| `consumed` | SAS match accepted; local activation authorized | server | `completed`, `activation_failed`, `abandoned` |
| `completed` | the requester promoted the key and acknowledged it | server, reported by device 2 | terminal |
| `activation_failed` | the requester still exists and reports that it did **not** promote the key | server, reported by device 2 | terminal |
| `abandoned` | the approver stopped waiting, and **activation was unknown at that moment**; late evidence may still be appended | server, declared by device 1 | terminal |
| `expired` | the TTL elapsed **while still `pending` or `approved`**, and expiry won | server | terminal |
| `aborted` | cancelled by an authorized party | server | terminal |

`pending → approved` is the **single-use reservation of the approval**;
`approved → consumed` **authorizes local activation**. Revision 1 called the
whole thing a single terminal transition and said the request was consumed at
approval, which contradicted its own table.

**Every transition not in the table is prohibited, including every
self-transition.** A retried operation returns the stored acknowledgement for
its `operation_id` (see A1) rather than re-entering a state it already
occupies; a request never moves backwards, and nothing leaves a terminal
state. Revision 3 listed the states without their exits, which left the two
questions below answerable in either direction.

**The TTL gates progress out of `pending` and `approved` only.** Unscoped, it
reads as a deadline on the whole request — and that reading is wrong in the
one case where it matters most. Once the `consumed` CAS has won before the
deadline, the human has already compared the SAS and device 2 is authorized to
activate. The local promote and the `completed` acknowledgement **must remain
resumable after the deadline passes**; otherwise a legitimate last-minute
confirmation is destroyed by a few milliseconds of clock skew or one slow
write, and the human is shown an attack-shaped failure produced by a timer.
Expiry may therefore be applied only to a request still in `pending` or
`approved`, and the deadline re-check is a **precondition of the `consumed`
CAS**, not of the steps after it.

**Scoping the TTL on the server does not scope it on the client**, and
revision 4 stopped at the server. The local deadline handler still erased the
staged plaintext and the one-time identity the moment the wall clock crossed
the deadline, which re-opens the same race one layer down: device 2 sends the
consume just before the deadline, the server wins the CAS inside it, the
acknowledgement is lost or the local clock crosses first, and the client —
still believing the request is `approved` — destroys the material the server
has already authorized it to promote. A server-supplied absolute deadline fixes
disagreement about *when* the deadline is; it does nothing about a response
that never arrived. So the rules below are normative on the client:

1. **The consume is durable and single-flight.** Before it touches the network,
   device 2 records `(operation_id, request_id, request version)` in the same
   durable outbox that carries the completion. A second attempt resumes that
   entry; it never starts a parallel consume.
2. **The deadline may stop a consume from starting. It may never resolve one
   that has started.** While an outbox entry is unreconciled, the request is not
   expired locally, no matter what the clock says.
3. **Reconcile before erasing.** On restart, or when the deadline passes with an
   unreconciled entry, device 2 re-fetches the stored result for that
   `operation_id`. If it is `consumed` or later, device 2 **proceeds to the
   promote even though the deadline has passed** — that is precisely the
   guarantee this section exists to give. Only an authenticated answer that the
   request is `expired`, `aborted`, or was never consumed permits erasure.
4. **Unreachable is not an answer.** If the server cannot be reached, the
   material stays staged and the client keeps retrying. Erasure on a timer
   while the outcome is unknown is the defect, not the safeguard.

Staged plaintext is still not kept forever: it has its own **retention bound**,
which is deliberately a different and much longer value than the pairing TTL
and is not synchronised with it. A bound that could elapse alongside the
deadline would recreate the race; one that cannot only costs the human a
re-request.

**That bound is the one explicit exception to rule 4, and it is written as an
exception rather than smuggled in as a detail.** Erasing while the outcome is
unknown trades recoverability for the guarantee that decrypted key material
does not sit on a device indefinitely. Revision 5 made the trade but got its
consequences wrong twice. It said the client "reports `activation_failed` at
the next opportunity" — but that is a CAS from `consumed`, and a client whose
outcome is unknown does not know the server is at `consumed`; the approval may
never have happened at all. And by erasing "the material" it invited the
implementer to take the request journal with it, which is U2 reproduced by
hand.

The exception is therefore scoped on both sides.

**Only the staged plaintext and the one-time secret are erased.** The request
id and version, the `operation_id`, the reference to the credential, and the
exact envelope digest survive until reconciliation is complete. They are not
key material; they are the evidence needed to close the request honestly, and
discarding them is exactly what makes a request unreportable.

**What happens on the next successful contact is a branch on the server's
state, never an assumption about it:**

| stored result / status | what device 2 does |
|---|---|
| `consumed` | report `activation_failed` — the CAS is legal and the statement is true, since no promote was ever committed |
| `expired` or `aborted` | accept that terminal state; there is nothing to report |
| `pending` or `approved` | the consume never landed. Do **not** start a new one, because the material is gone. This branch only exists when the retention bound elapsed early relative to the TTL (a stalled worker, a suspended device); **device 2 aborts the request with its own requester credential**, which it still holds in this case, rather than leaving a live request the human can still approve into nothing |
| `completed` | a local invariant violation: with no completion outbox entry this device cannot have promoted. Fail closed and surface it rather than reconciling it away |
| `abandoned` | the approver closed it while this device was dark; accept the terminal state and re-request |

**Abort is likewise limited to `pending` and `approved`.** After `consumed`
there is nothing left to cancel: device 2 already holds decrypted material and
the authorization to promote it, so an abort arriving then would either be
ignored — making it a lie to whoever issued it — or would have to reach into
another device's local key state, which no server-side transition can do. An
abort attempted against `consumed` or any terminal state is refused with the
current state rather than silently accepted, so the human learns that the
window for cancelling has closed. The remedy after `consumed` is `abandoned`
below — a different statement, because by then a key may actually exist.

**`consumed` is not "committed".** Revision 2 said it was, while the
durability order puts the local promote *after* the server CAS — so a crash
in between leaves the server reporting a completed delivery while device 2
holds no active key. That is the same class of lie this revision exists to
remove. `consumed` therefore means only that the human accepted the SAS and
local activation is authorized, and `completed` is a separate,
idempotently-acknowledged state that device 2 reports **after** the promote.
Until that acknowledgement arrives, device 1 says "confirmed; the other
device is finishing" rather than claiming completion.

**A requester that loses the staged material before promoting it must
terminalise the old request, not merely abandon it.** Revision 3 said recovery
is a new request, which is true for device 2 and useless for device 1: nothing
in the protocol would ever have moved the old request off `consumed`, so
device 1 would display "the other device is finishing" until the human gave
up — and the TTL cannot rescue it, precisely because expiry no longer applies
past `consumed`. Device 2 therefore reports **`activation_failed`**: an
authenticated, idempotent terminal transition carrying the request id and
version, admitted through the same dedicated path as the `completed`
acknowledgement.

`activation_failed` is refused once the key is promoted. The check is **local
first** — device 2 must not send it when its own completion outbox records a
committed promote — and is enforced again by the server as a **CAS from
`consumed`**, so a retry that crosses a successful `completed` cannot
un-complete a delivery. The two are mutually exclusive outcomes of the same
transition and whichever is recorded first wins; the loser receives the
recorded state rather than an error, because after a crash device 2 genuinely
cannot know which of its attempts was received.

**But `activation_failed` cannot be required of a device that no longer
exists.** Revision 4 made it mandatory for "the one-time identity or the staged
material is gone (reinstall, keystore loss)" — and a reinstall destroys the
request journal and the credential the report itself needs. There would be no
authenticated party left to send it. The two losses must be separated, because
only one of them leaves a reporter behind:

- **The staged bundle is lost, the durable request journal and the credential
  survive** (a wiped cache directory, a failed atomic promote). Device 2 can
  still authenticate and still knows the request id and version, so it reports
  `activation_failed` and the human re-requests. This is the case revision 4
  described.
- **The installation is lost** (reinstall, keystore loss, a destroyed or
  discarded device). Nothing on device 2 can be reconstructed — not the
  credential, not the request id, in general not even the fact that the request
  had reached `consumed`. **No report is possible from that side at all**, and
  no amount of local journalling fixes it, because the journal dies with the
  installation.

The second case needs a different authority, and the only party that is both
stuck and still authenticated is **device 1**. It may therefore declare
**`abandoned`**: an authenticated terminal transition from `consumed` under the
same owner, meaning **"the approver stopped waiting at time T, and activation
was unknown at that time."** The wording matters and is fixed here rather than
left to the reader: this state must not be defined as "no completion is coming",
because a device that returns after the deadline disproves exactly that (see the
late-evidence rule below). A statement about what was known at T stays true no
matter what arrives afterwards.

**`abandoned` is deliberately not `activation_failed`, and deliberately not
`aborted`.** `activation_failed` is a positive statement by the authoritative
party that no key was promoted — strictly stronger information, and it implies
no further action. `aborted` says the delivery never happened at all. Neither
is true here: after `consumed`, device 2 may in fact hold a live key, and the
approver cannot distinguish "the device was wiped" from "the device promoted
the key and can no longer reach the server" or from "the device is in someone
else's hands." Collapsing the three would either force needless key rotation
after an ordinary failed activation, or — far worse — let a genuinely
unknown activation read as "not activated". So `abandoned` terminalises the
request *and* tells the human the epoch must be treated as possibly delivered:
if the device is not recoverable and trusted, rotate.

`abandoned` is permitted only from `consumed`, only after a **server-supplied
completion deadline** has elapsed, and it loses to a `completed` or
`activation_failed` that is recorded first — the same CAS from `consumed` that
those two contend on. The completion deadline is a separate value from the
pairing TTL and must be: the TTL governs the human's approval window and no
longer applies once `consumed` is reached, so it cannot also bound the
activation that follows it. It exists to keep the approver from abandoning a
device that is merely slow, and it is what device 1 is counting down while it
displays "the other device is finishing."

**That deadline is created by the `consumed` CAS itself.** It cannot be pinned
at registration next to `expires_at`, because at registration the time of the
consume is not yet known. The server records
`completion_deadline = <authoritative consumed_at> + <duration fixed in the
spec>` **once, in the same transaction as the `consumed` CAS**, returns it in
the status response alongside the request version, and never extends or
recomputes it. The `abandoned` CAS re-checks it against the server clock;
device 1's countdown is display, not authority. Revision 5 introduced this
deadline as a gate without saying where it came from — which left it
unimplementable, and left a server free to move it.

**A terminal `abandoned` must not discard a late completion.** The state
explicitly covers "device 2 promoted the key but cannot reach the server", so
that device can return after the deadline, and its completion outbox will
faithfully re-send the acknowledgement it still owes. If the CAS simply
refuses, the protocol has been handed a new authenticated fact — a key really
was activated — and thrown it away, leaving the request reading "activation
unknown" forever. That is this document's own defect one more time: an
observation exists and the design declines to record it.

Overwriting `abandoned` with `completed` is wrong in the other direction, and
worse. The human already acted on "unknown", possibly by rotating the epoch,
and rewriting the state to a clean success destroys the record of why.

So the state stays terminal and **the late acknowledgement is recorded beside
it, append-only, as late-completion evidence**: authenticated, bound to the
request id and to the state version the request was frozen at, carrying when it
arrived. Status reports it and audit retains it.

**Evidence gets its own counter, because the request version cannot serve
both.** The status contract says a client rejects a mutation carried at an
unchanged version — so an append that leaves the version alone is
indistinguishable from a server lying about a terminal request, while advancing
the request version would leave a terminal state with a moving concurrency
token and no defined precondition for the acks that bind it. Neither is
acceptable, so they are separated:

- The **request version counts state transitions only**, and is **frozen when
  the request becomes terminal**. Every CAS precondition keeps referring to it.
- **`evidence_revision`** starts at zero and increments **once per accepted
  evidence append**, in the same transaction as the append.
- Status returns **both**, and the client's freshness rules apply per counter: a
  lower value of either is a regression and is rejected; a **state** change at
  an unchanged request version is rejected; an **evidence** change at an
  unchanged `evidence_revision` is rejected.
- The late acknowledgement binds the **frozen request version**, not
  `evidence_revision` — the returning device cannot know how many evidence
  rows it is arriving behind, and requiring it to would make a correct retry
  fail.

**The late acknowledgement is the same operation as the ordinary one, so it
obeys the same ledger.** It arrives from the same durable outbox, carrying the
same `operation_id`, and "append-only" on its own would let every lost response
add another row. It is therefore pinned to the operation ledger A1 already
establishes:

- The **same `operation_id` with a byte-identical canonical request returns the
  stored acknowledgement** and results in **exactly one** evidence row, however
  many times it is retried.
- The **same `operation_id` with any field differing** — request, version,
  evidence payload, anything — **fails closed with a conflict** rather than
  recording a second version of events.
- An acknowledgement that won **before** the request became `abandoned` is
  stored as `completed`; one recorded **after** is stored as evidence. A
  response-loss retry of either converges on **its own** stored result. The
  outcome is decided once, by whichever reached the server first, and no retry
  can move a request across that line afterwards.
- The state transition, the evidence append, **the applicable counter update
  (`evidence_revision` for a late append, the request version for a state
  transition)**, and the stored-result write happen in **one transaction**. A
  crash cannot leave evidence without a result, or a result without the row it
  describes.

Late evidence is not a reason to un-rotate anything; its value is the opposite.
It tells the human that an epoch they treated as possibly-delivered was in fact
delivered, and to which device, which is what makes the earlier rotation
decision reviewable rather than unfalsifiable.

**Any live installation under the owner holding an approver credential may
declare `abandoned`, not only the installation that approved.** Requiring the
original approver would rebuild the failure this state exists to solve, since
that installation can be precisely the one that is gone. The declaring
installation's identity is recorded with the transition, so "who closed this,
and when" is an audit fact rather than an inference.

**A new request never inherits an old one's outcome.** Re-requesting while the
previous request is still unresolved is the normal case here, not the edge one:
the `abandoned` path cannot resolve until the completion deadline, and the
human will reasonably start again before then. The two therefore coexist as
distinct `request_id`s with distinct status entries, and the client must show
them as separate attempts. A later request reaching `completed` must not close,
recolour, or hide the earlier one — the earlier request terminalises only
through its own observed transition. Otherwise a successful second pairing
would silently present the first as finished, which is the same "unobserved
outcome rendered as success" this design has been removing throughout.

Late-completion evidence is scoped the same way: it belongs to the
`request_id` that produced it and is never absorbed into a later request's
success. The two attempts can each have activated a key, and which one did is
the whole question.

**Abort authority** is the requester's credential and an authorized approver
under the same owner — not "either side" unqualified. State, version and
expiry are re-verified inside the lock, and that state check is exactly the
`pending`/`approved` restriction above.

**Abort is a credential-authorized operation**, and the server sets
`aborted` and appends the notice **in one transaction**. The notice carries
no end-to-end signature, but it is a server-authenticated control row bound
to the request and its version, admitted through the same dedicated path, so
an ordinary writer cannot inject one. That is what makes immediate
termination safe. Revision 2 argued instead that a forged abort is merely
denial of service — which is a reason to *tolerate* a malicious server, not a
reason to skip authentication. A genuinely unauthenticated notice could only
be a hint, and would have to be confirmed by an authenticated status query
before terminating anything.

### Observability

The load-bearing table. Honest-server crash recovery and the malicious-server
SAS guarantee are deliberately separate columns: server-reported status can
reconcile abort and expiry, but it cannot substitute for the SAS, because a
malicious server is exactly the party reporting the status.

| transition | how device 1 observes | how device 2 observes | fail-closed when unobservable |
|---|---|---|---|
| `pending` created | approver's pending list, authenticated | local; it created the request | — |
| `→ approved` | it performed the CAS | **authenticated request-status query, independent of payload arrival** | show "waiting", never "approved" |
| payload delivered | delivery ack | control row arrives on the stream | remain waiting until the deadline |
| `→ consumed` | **status query** | it accepted the SAS | device 1 shows "delivered, awaiting confirmation" |
| `→ completed` | **status query**, after device 2 acknowledges | it promoted the key | device 1 shows "confirmed; the other device is finishing"; **"done" is shown only when `completed` is actually observed on the status query**, never inferred from delivery, from elapsed time, or from the absence of an error |
| `→ activation_failed` | **status query** | it found the staged material lost and reported it | device 1 keeps showing "the other device is finishing" and offers re-request; it never renders an unobserved outcome as success |
| `→ abandoned` | it declared it, after the completion deadline | often never — the case it exists for is a device that is gone; a device that *returns* sees it on the status query, and appends late-completion evidence if it had in fact promoted | device 1 keeps showing "the other device is finishing" until the completion deadline, then offers to abandon; never before |
| `→ aborted` | status query | **authenticated abort control row on the same path**, plus status query | treat as still pending until the deadline |
| `→ expired` | **server-supplied absolute deadline** | same | at the deadline, stop *starting* operations — do not resolve one already in flight; a request at `consumed`, or with an unreconciled consume, is never expired locally |

Three consequences, all of which revision 1 lacked:

- **Request status is queryable independently of the payload.** Without it,
  device 2 cannot distinguish "not approved yet" from "approved, delivery in
  flight" — states that call for opposite human actions ("wait" versus "go
  look at device 1"). On a mobile client, where stream arrival depends on push
  and connectivity, these diverge routinely rather than exceptionally.
- **Abort is delivered as a server-authenticated control row on the same
  path**, reusing the extension point control messages already established,
  and admitted through the same dedicated operation so an ordinary writer
  cannot forge one. It terminates the request immediately rather than
  prompting the human, and the human re-requests.
- **The deadline is an absolute time supplied by the server**, not a local
  countdown from registration. A device that was offline for five minutes
  otherwise displays time that does not exist, which is the same class of
  defect as the false "expired" above: the human believes a code is valid when
  it is not.

## Outcomes the human sees

Each is a distinct protocol outcome, because collapsing them produces
misleading text, and one collapse is actively dangerous.

| outcome | meaning |
|---|---|
| expired | the deadline passed; re-request |
| unknown code | no such pending request (post-authentication only) |
| cap reached | too many pending requests |
| **SAS mismatch** | **the keys differ; treat as an attack** |
| epoch rollback refused | the delivered epoch is older than the canonical one; not a comparison failure |
| undecryptable delivery | addressed to this request but this device's key does not open it — the expected result of substitution |
| conflicting delivery | a *different* envelope arrived for one `request_id`; abort |
| staged material lost | the bundle or the one-time identity is gone but this installation survives; re-request — and if the request had reached `consumed`, report `activation_failed` first, so device 1 stops waiting |
| installation lost | reinstall, keystore loss, or a device that is gone; **nothing can be reported from this side** — device 1 resolves it with `abandoned` |
| activation failed | seen on device 1: the other device is still there and states it did not promote the key; the request is dead, re-request, no rotation needed |
| abandoned | seen on device 1: no completion arrived by the completion deadline and **activation was unknown at that moment**; the request can no longer transition, but the evidence channel stays open — a device that returns later still records that it activated — and if that device is not recoverable and trusted, rotate the epoch |
| delivery after expiry | a valid-looking payload arrived past the deadline; discard and re-request |
| cannot reach the server | distinct from "not approved yet"; waiting does not help |

**SAS mismatch must not share wording with any of the others.** "Local key
lost" and "undecryptable delivery" both surface as "it would not open", and
if either is worded like a mismatch, a real substitution gets dismissed as
"the key probably got wiped again".

**Conflicting delivery**: single-use CAS stops a second *approval*, not a
second *envelope*. But "a second envelope aborts" — revision 2's rule — would
break the transport, because re-observing a row is normal: pull retries,
resync, and the approver's own echo all re-present the same delivery, and
at-least-once transport would abort every pairing.

The two cases are different and must be separated. **Re-observing the same
`(server_seq, wire_id, exact envelope digest)` is exact replay and is accepted
idempotently.** Only a **conflicting** second delivery for the same
`request_id` — a different `wire_id`, digest, recipient, or version — aborts,
because first-wins there would let an attacker race a substituted blob against
the real one.

That abort is a real `aborted` transition, and it is available because a
conflicting delivery can only be *handled as one* while the request is still
`approved`. **A conflicting envelope observed after `consumed` is rejected and
discarded locally instead**, since the request may no longer be aborted and
there is nothing left to protect: the SAS the human already compared binds the
one envelope that was accepted, so a later blob cannot displace it. It is
still reported as a conflicting delivery, because a second envelope arriving at
all is worth showing the human.

**Delivery after expiry** is discarded rather than accepted, and the TTL is
not extended and does not pause at approval. A 14th-minute approval whose
payload crosses the deadline is a re-request, not a special case — with a
named outcome so it is never confused with an attack.

**Epoch rollback** cannot be judged against "an epoch I already hold": a new
device holds none. The canonical epoch snapshot digest and revision chosen by
the trusted live device are bound into the payload and the SAS, and the
requester verifies the hash chain and shape.

## Durability ordering

Undefined crash ordering leaves the server and the device disagreeing in
whichever direction the crash falls. The order is:

1. stage the decrypted bundle durably (`0600`, no-follow);
2. record the human's SAS-match decision durably;
3. CAS an unexpired `approved` to `consumed`;
4. promote the staged material to the local active key **and record
   `(request_id, request version, completion pending)` in a durable local
   completion outbox — in one commit**;
5. acknowledge `completed` to the server, retrying until it succeeds or the
   stored result for that `(operation_id, request)` is re-fetched and found
   already recorded, then clear the outbox entry.

**Step 4 is one commit, not two.** Revision 3 ordered the promote correctly but
gave the acknowledgement no durable owner, so a crash between promoting the key
and sending `completed` left device 2 entirely functional — its key is active,
so nothing on that device would ever retry — while device 1 waited on a state
that could no longer arrive. Writing the outbox entry in the same commit as the
promote is what makes the acknowledgement survive that crash, and what keeps
the two from disagreeing in either direction. The acknowledgement is idempotent
for exactly that reason: after a crash device 2 cannot know whether its last
attempt was received.

The outbox is also what separates the two terminal reports. An entry recording
a committed promote **forbids** `activation_failed`; staged material that is
gone with no such entry **requires** it. Neither report is a judgement call at
the point of failure.

A lost consume acknowledgement is re-obtained idempotently for the same
request. A crash after `consumed` but before step 4 resumes from the staged
material; a crash after step 4 resumes from the outbox. Mismatch, abort and
expiry — all of which can occur only before `consumed` — erase the staged
plaintext and the one-time identity, **subject to the reconciliation rule
above**: expiry never erases while a consume is unreconciled, because at that
point the client does not yet know that it is expiry it is handling. The
deadline is re-checked immediately
before the `consumed` CAS and winning that CAS after expiry is prohibited;
steps 4 and 5 are deliberately **not** gated on it, for the reason given under
"State, authority, and observation".

Revision 1's claim that expiry "leaves no key material behind on either side"
was wrong as written, since the ciphertext remains in the stream. It is scoped
here to the request-specific secrets and staged plaintext, which is what can
actually be erased.

## Client obligations for a non-addressee

A `pair-v1` envelope that is not for this client is **semantically inert after
strict validation** — not skipped unvalidated. A non-addressee still validates
the outer schema, bounds, canonical base64, age framing and header bounds, and
stanza grammar, and treats malformed or oversize input as durable protocol
corruption. It does **not** decrypt. Selection is by `(cipher, key_id)` against
a request this client is itself waiting on, so no trial decryption occurs.

Beyond that it must not report the envelope as an error, must not count it
unread, must never hand it to an agent as message content, and must not
re-emit it. The row stays in the stream; only rendering and dispatch are
suppressed.

**A client with a background notification path must skip `pair-v1`
unconditionally there** — no decryption attempt, no notification, no handoff
record. On mobile the first code to touch an envelope is an out-of-process
notification extension whose only job is to decrypt and display; left alone it
would post a decryption-failure notice to every device on the team each time
anyone pairs, which is exactly what the inertness rules forbid, one layer
below where those rules were written. The selection rule is a local lookup
that a separate process may be unable to perform, so it must not be required
to: dispatch on `cipher` alone is sufficient, and pairing needs no
notification because the human is already looking at the screen to compare the
SAS.

This does not weaken the strict-validation rule above; it divides
responsibility. The notification path performs **no validation and no
decryption** — it only declines to act. The strict outer and profile
validation still happens, unconditionally, on the main pull path, which is the
one that decides whether a row is well-formed or is durable protocol
corruption. Skipping by `cipher` alone is safe precisely because it defers
rather than replaces that check.

## Unchanged

Zero new cryptography; no new transport (delivery is a control message on the
existing stream, through its own admission path); `key show --reveal-secret`
and `key import` remain permanently for offline and self-hosted setups, with
the SSH one-liner documented as a fallback; and the skeleton stays generic
enough that a QR path can later replace the visual comparison.

## The status query

Because so much observability now rests on it, its response is pinned too:

- a **monotonic request version** alongside the state, counting state
  transitions only and frozen once the state is terminal;
- a **monotonic `evidence_revision`**, counting accepted evidence appends;
- an **immutable `expires_at`**;
- an **immutable `completion_deadline`**, present once the request has reached
  `consumed` and fixed by that transaction — never recomputed, never extended;
- the delivery identity and digest, when one exists;
- **late-completion evidence**, when any has been appended to an `abandoned`
  request, with its arrival time;
- `no-store`.

A client **rejects a regression in either counter, rejects a state change
carried at an unchanged request version, and rejects an evidence change carried
at an unchanged `evidence_revision`.** The rule is per counter precisely so that
appending evidence to a terminal request is not indistinguishable from a server
mutating one. The absolute deadline is pinned locally from the
registration response and is never extended by a retry or by a later status
response — otherwise a server could keep a request alive by answering
generously.

## Before implementation

These are gates on starting the work, not open architecture questions.

**The code entropy, the SAS entropy, the hash construction and domain
separation, and the attempt-rate limits must be fixed together, as numbers,
in the versioned spec.** Revision 2 deferred them to "the implementation
review" as if they were independent tuning knobs. They are not: the SAS length
that is sufficient depends on the attempt rate and the TTL, and the code
length that is sufficient depends on the cap and the same rate. Choosing any
one of them alone is choosing the others by accident.

**The Stage 1/2 record kind** that carries the control row (above) must be
agreed with the storage/server owner.

**The completion deadline and the staged-material retention bound are fixed as
numbers in the same spec, and explicitly not derived from the TTL.** They are
separate quantities answering separate questions — how long device 1 waits
before it may abandon, and how long device 2 holds decrypted material with the
outcome unknown — and the reason both exist is that neither may be allowed to
elapse alongside the pairing deadline. Deriving either from the TTL would
reintroduce the coincidence that U1 was about.

## Open

- Migration of the wire shape into a versioned `docs/spec/` profile.
- Console copy that says "paste this" needs rewording now that pairing is the
  primary path.
