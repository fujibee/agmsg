# Handing an authentication result to a host's authorization decision

> **SUPERSEDED.** The onboarding this describes was replaced by
> [`docs/design/remote-sync.md`](../remote-sync.md), which states the replacement
> from its own side. Kept as design history: the reasoning here is why the
> current shape is what it is, and the findings it records were closed rather
> than dropped. Do not build to it.

**Status: review passed; adoption undecided.** Revision 5. Design study for a
seam the reference server does not have yet. It is deliberately narrow: it does
not change who may connect, it changes how many times a request establishes
*who is calling*, and how that answer reaches a decision the reference server
does not make itself.

**Nothing here is a settled interface.** The review rounds below found and
closed defects, which is a statement about quality and not about adoption: an
OSS interface is a promise to users, and that decision belongs to the project
owner rather than to a review thread. Read every normative-sounding sentence
here as "what this design proposes, if adopted". Implementation has not started
and must not start on the strength of the review alone.

Revision 1 was returned with five blockers. **B1**: it asserted the state a host
authorizes against "lives beside the credential" and could therefore be read in
the authentication transaction — that state is host-owned, so no such snapshot
exists, and reaching for it would have held a database transaction open across
host I/O. **B2**: the request memo and `includeRevoked` were left undefined
together, so call order could decide whether a revoked credential was accepted.
**B3**: a read/write flag is too coarse to express operations that must stay
available under a deny. **B4**: the contract fixed the hook's *result* but not
its *execution lifetime*, so a timeout would return a deny while the hook kept
running. **B5**: "may not mutate" was prose, not a runtime property.

Revision 2 closed those and exposed three more. **R1**: making the lookup
state-neutral meant a revoked credential resolved as an identity, so handing it
to a host hook and returning a policy deny would make revoked distinguishable
from invalid, an existence oracle the opaque 401 exists to prevent. **R2**: the
execution-lifetime section claimed to fix when a hook *stops running*, which an
`AbortSignal` cannot deliver, and then contradicted itself by accepting late
completions. **R3**: "an unclassified route fails to compile" was asserted
without a mechanism that would make it true.

Revision 3 closed R1 and R2 and left two. **S1**: it kept saying
`credential.revoke` must stay available while everything else is denied, and
then routed it through the host hook — where a policy deny or a hook outage
makes it unavailable. Naming an operation is not the same as guaranteeing it.
**S2**: naming one helper is not enforcement either; a module holding the
Fastify instance can still register a route directly and compile.

Revision 4 closed both and left two consistency defects. **T1**: the gate
requiring "exactly one hook invocation" for a valid credential contradicted the
escape hatch, which requires zero. **T2**: "the hook is unable to authenticate
again" claimed more than an ABI can deliver — the same overreach as S2, in the
sentence that congratulated itself for avoiding it.

## The defect

`authenticateCredential` is not a read.

```
UPDATE credentials
   SET last_active_at = CASE WHEN revoked_at IS NULL THEN clock_timestamp()
                             ELSE last_active_at END
 WHERE team_id = $1 AND secret_digest = $2
   AND ($3::boolean OR revoked_at IS NULL)
 RETURNING credential_id::text, revoked_at IS NOT NULL AS revoked
```

It is a write that returns an identity. Calling it twice in one request is not
idempotent in the way callers assume: the second call moves `last_active_at`
again, so a field that is supposed to mean "when this credential was last
presented" silently starts meaning "how many times our own code asked."

That would be a minor wart if nothing needed to ask twice. Something does. A
host embedding this server makes its own admission decision from the identity
this server just established. Today its only options are to authenticate again
(double side effect) or to derive identity separately (two sources of truth for
who is calling).

The pipeline already leaks the same shape internally. `scopedCredential` returns
`{ teamId, credential }`; `scopedTeamId` calls it and **discards the
credential**, leaving any later consumer no way back to it.

## What this is not

**Not the admission seam.** Admission decides whether a payload may enter the
stream. This decides whether an authenticated caller may proceed at all, and it
runs earlier and knows less.

**Not a policy, and not a place to keep one.** The reference server gains a
place to ask and a guarantee about what it hands over. It does not learn which
states are allowed, and — the correction revision 1 needed — it does not
learn what the states are. A host that installs nothing sees today's behaviour
exactly.

## The state belongs to the host, and so does reading it

Revision 1 said the effective state "lives beside the credential" and could be
read in the authentication transaction. That was asserted, not checked, and it
is wrong: the state a host authorizes against is the host's own, held in the
host's own authority. Nothing about it sits beside `credentials`.

The consequence is not cosmetic. A single-transaction snapshot across two
authorities does not exist, so writing one into the contract would produce
either a lie or, taken literally, a database transaction held open across host
I/O — a lock whose duration is set by someone else's network.

**So the seam carries identity, not state.** The server hands over what it
authoritatively knows; the host reads its own state from its own authority and
decides.

**The TOCTOU this accepts, stated rather than hidden:** the host's state may
change between its read and the effect of the allowed operation. This design
does not close that, because closing it would require the server to join a
transaction it cannot see.

**Strict cross-authority serialization is a non-goal**, and it is worth being
exact about why re-checking on the host side is not a workaround: that
serializes the host's own effects only. It cannot be made atomic with a message
insert happening in this server, so an operation already in flight when the
state changes will still land. What the seam offers is a decision point, not a
barrier. Naming the gap is the point — an unstated one gets rediscovered as a
bug.

## The shape

**One authentication per request, and it is the only writer.**

1. **Canonical authentication resolves the credential row once, state
   neutral.** It looks the row up and reports what it found, including whether
   it is revoked. It does not decide whether revoked is acceptable.
2. The result is **memoized on the request**, keyed by the fixed request inputs
   (team and credential digest), not by the caller's intent. Every later
   consumer, `scopedTeamId` included, reads the memo. A second call within the
   same request performs no write.
3. **Each operation's authorization decides whether a revoked credential is
   acceptable.** `includeRevoked` becomes a property of the operation rather
   than of the lookup.
4. The hook is handed a **frozen projection** of the memo — not the memo, and
   not the pool or the request.

**The built-in gate runs before the host hook, and credential validity never
leaves this server.** State-neutral lookup resolves a revoked row as an
identity, so without an ordering rule that row would reach the host, come back
as a policy deny, and thereby answer the question the opaque 401 exists to
refuse: whether the credential exists. Revocation is this server's authority,
not the host's, and a host must not have to reimplement it. The order is fixed:

1. Resolve the credential row once, state neutral.
2. **This server's built-in operation gate.** `credential.revoke` accepts a
   revoked credential; every other operation rejects it with the same opaque
   401 an invalid credential gets, and **the host hook is never called**.
3. Only an identity that passed the built-in gate is offered to the host hook.

Step 2 is what keeps the seam from becoming a credential-existence oracle, and
it is why the contract test below has to cover invalid × revoked across *every*
operation rather than only checking that call order does not matter.

Point 3 repairs a defect revision 1 had built in. With `includeRevoked` as an
argument to the lookup *and* a shared memo, the first caller decides for
everyone: a self-revocation route authenticating with `includeRevoked=true`
memoizes a revoked identity that a later ordinary route reads as valid, and the
reverse order blocks a legitimate self-revocation. A state-neutral lookup
removes the ordering dependence entirely: one row, and one policy question
per operation.

Point 4 matters because "must not mutate" written in a document is not a
property of the running system. The hook receives a frozen readonly copy; the
memo stays private to the request pipeline. A hook that modifies its copy
corrupts nothing, and later consumers keep reading the one truth.

The hook is given a value, not the pool and not the request. A hook holding the
tools to re-authenticate eventually will — under a retry, inside a helper, or
in a branch nobody exercised — so the ABI does not hand them over.

**That reduces accidental re-authentication; it does not make it impossible,**
and revision 4 claimed otherwise. The hook is host code: it can capture a pool
in a closure, or import the exported authentication function directly. No shape
of ABI prevents that. What can be stated is four separate things:

- The pipeline this server owns calls canonical authentication **once** per
  request.
- The hook ABI **offers no re-authentication capability**.
- The host **must not** re-authenticate — an obligation of composition, not a
  property of the type.
- The contract test **instruments the authentication function** and pins the
  total call count at one for a canonical host caller.

A malicious or careless host cannot be typed out of existence. Saying so is
better than a guarantee that quietly fails to hold.

## What crosses the seam

The hook receives, frozen:

- `team_id` and `credential_id`
- whether the credential is revoked
- the **operation**, as a closed discriminated enum

It returns an allow, or a deny carrying a machine-readable reason and an
optional retry hint. Nothing else.

**The operation is an enum, not a read/write flag.** A boolean cannot separate a
capabilities read from a message read, which a host may well treat differently.

    capabilities.read
    members.read
    messages.read
    messages.write
    read-state.write

**`credential.revoke` is deliberately not in that list.** Revision 3 put it
there and argued in the same breath that it "must stay available precisely when
a host is denying everything else" — which the design then made false, because
an operation routed through the host hook is unavailable exactly when the host
denies or the hook is down. Classifying an operation distinguishes it; it does
not keep it working.

Self-scoped revocation is something this server can verify on its own: the
credential presented is the credential being revoked. So it **bypasses host
authorization entirely** — a built-in escape hatch, hook called zero times. A
compromised credential stays revocable while a host is refusing everything else
and while the host's hook is broken, which is precisely when someone needs to
revoke it.

Authenticated routes therefore fall into three classes, not two:

| class | host hook | examples |
|---|---|---|
| host-authorized | called once | capabilities, members, messages, read-state |
| built-in escape hatch | **never called** | self-scoped `credential.revoke` |
| public / unauthenticated | never called | health, pairing exchange |

Revoking a *different* credential is not the escape hatch and keeps its existing
authorization; the bypass rests on the server verifying self-scope, and nothing
weaker.

The alternative, leaving revoke under host authorization, is coherent only if
this document also withdraws the availability claim and states plainly that a
host outage blocks revocation. That trade is worse for the failure it matters
in, so it is not taken.

The enum is **closed**, and adding a route without classifying it must fail.
Two revisions of this document asserted that without a mechanism, so the
mechanism is part of what the design asks for rather than an implementation
detail.

Adding a helper is not enough. As long as the module defining routes holds the
Fastify instance, `app.get(...)` remains available and compiles, and "register
public routes on a separate path" is a convention someone can skip — which is
what revision 2 claimed and revision 3 repeated.

**So the raw instance does not reach route-defining code.** An outer plugin owns
it and the wiring around it (parsers, hooks, error handling). Route modules
receive a registrar exposing exactly three capabilities and nothing else:

    authenticatedRoute(operation, ...)     // operation is required
    builtInAuthenticatedRoute(...)         // the escape hatch, no hook
    publicRoute(...)                       // explicitly unauthenticated

With no `app` in scope there is no bypass to write, and a route that omits its
operation does not compile because no overload exists without it. Obtaining the
scoped identity and invoking the hook happens inside the registrar, so a handler
cannot reach `scopedCredential` or `scopedTeamId` on its own.

**The registrar is what this design proposes, not one of two options.**
Revision 4 offered a
lint rule as an inline fallback, which puts the weaker choice in reach of
whoever is implementing at the time — and this document has already watched an
enforcement claim survive three revisions by being easy to defer. Substituting a
different mechanism is a design change and takes a re-review, not a judgement
call at the call site.

## Execution lifetime, not just the result

Fixing what the hook *returns* is not enough, but the contract cannot fix when
a hook stops running either. Revision 2 claimed it could; an `AbortSignal` is a
notification, and a hook that ignores it keeps executing whatever the server
does. Saying otherwise while also accepting late completions two lines later was
a contradiction inside one section.

What can actually be contracted is narrower, and is stated as three separate
things rather than one overstated one:

- **When the server stops awaiting.** At the deadline it finalizes the response.
  This is the only timing guarantee, and it is the server's own behaviour.
- The hook is invoked with an **`AbortSignal`** carrying that deadline and is
  **obliged** to honour it — an obligation on the host, not a property the seam
  enforces.
- The hook must be **read-only and idempotent** with respect to the host's own
  state. The seam cannot enforce that, so it is stated as an obligation and
  paired with the signal rather than assumed.
- **A late result never affects the decision.** It is discarded, and its
  arrival is recorded — a hook that routinely finishes after the deadline is a
  defect an operator needs to see.

That last record has to be bounded before implementation, not after. During the
outage it is designed to reveal, every request produces one, so it scales with
traffic exactly when the system is least able to absorb it. It is rate-limited
or sampled with a fixed cardinality bound, under whatever bounded-logging policy
the server already applies elsewhere.

## Two different failures, two different answers

A **policy deny** is the host's considered answer, and carries its
machine-readable reason to the caller.

A **hook outage** — a throw, or a deadline exceeded — is not a policy answer
and must not be dressed as one. It denies, and it reports a generic
authorization-unavailable failure, distinct from any policy reason.

Collapsing them lets a host exception silently become "your access was refused
for reason X", which is a false statement to the caller and, in the outage where
it matters most, makes a broken hook indistinguishable from a working one
refusing everybody. The distinction has to reach the HTTP contract, not only the
server's logs.

Fail-closed here is the opposite of the fail-open convention used elsewhere in
this repository, and deliberately so: fail-open is right when the cost of the
failure mode is wasted work, and wrong when it is unauthorized access.

## `last_active_at` under a deny

**It moves** — for a non-revoked credential. The precise meaning is **"last
presented while not revoked"**, not "last presented": the existing
`CASE WHEN revoked_at IS NULL` guard already exempts revoked rows, and calling
the field "last presented" while that guard stands would be a second small lie
of the kind this document exists to remove.

Within that scope, presentation is a fact about the caller, not about the
outcome. A host that must distinguish "quiet because nobody used it" from "in
use but refused" needs it, and a team being refused every few seconds must not
read as dormant. Bumping only on allow would make the field mean "last
successful use" — also a useful fact, but one whose definition would change
the moment a host installs a hook, and a field whose semantics depend on an
installed policy is a field nobody can build on.

## Before implementation

These are gates on starting, and they are contract tests rather than prose:

- **Invalid × revoked, across every operation.** For each operation in the
  enum, an invalid credential and a revoked one must produce the same status,
  the same body, and the same hook call count — zero — except for
  `credential.revoke`, where a revoked credential proceeds. Checking only that
  call order does not matter would miss this entirely, which is how it got in.
- **Valid credential, by route class** — one line each, because a single
  "exactly one hook invocation" rule contradicts the escape hatch and would let
  whichever test was written first decide:
  - host-authorized operation: **one** authentication write, **one** hook call,
    however many consumers read the identity;
  - self-scoped `credential.revoke`, valid or revoked: **one** authentication
    write, **zero** hook calls;
  - public route: **zero** authentication writes, **zero** hook calls.
- **Structural route coverage**: every hook-covered route reaches the hook
  through the registrar, no handler calls `scopedCredential` or `scopedTeamId`
  directly, and a raw registration fails.
- **The escape hatch stays open under a hostile host.** With a hook that denies
  everything, and again with a hook that throws or hangs, a self-scoped
  `credential.revoke` still succeeds and the hook is called zero times. An
  invalid credential gets the opaque 401; revoking a credential other than the
  presented one keeps its existing rejection.
- **Deny output is bounded.** The reason and retry hint come from an untrusted
  extension: they are schema-checked, length- and cardinality-capped, and
  mapped to a safe HTTP shape. An arbitrary string reaching error details or
  logs is a disclosure and log-cardinality vector, not a diagnostic.
- **Deny, outage, and timeout** are distinguishable at the HTTP contract.
- **A mutating hook** cannot affect what later consumers see.
- **Late completions are bounded**: the record is rate-limited or sampled, so
  a sustained outage does not scale logging with traffic.
- **No hook installed**: behaviour is identical to today.

The **hook deadline** is a number and belongs with the other server timeouts in
the same spec, not invented at the call site.

## Open

- The one-hook-versus-two question is settled above rather than left open: a
  single hook with the operation discriminator composes better and can express
  the escape hatch.
- Which existing bounded-logging policy the late-completion record attaches to.
  That it must be bounded is settled above; which mechanism the server already
  has is a question for the server owner.
