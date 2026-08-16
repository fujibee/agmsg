# Adaptive sync catch-up (design draft)

Status: DRAFT for review. OSS-side; destination `integration/remote`.
No wire-contract or schema change → no ADR (see adr-discipline); a design doc
suffices. If the design later needs to touch `server/spec/v1.md`, that part
gets its own ADR judgement.

## Problem

`remote-sync run` polls in cycles bounded by `--limit N` (default 100) with a
`--interval SECONDS` (default 5) wait between cycles. That cadence is correct
for **steady state** (keep latency low, don't busy-poll). It is wrong when a
large backlog exists: 90,000 messages at 100/cycle + 5 s/cycle is **~900
cycles × 5 s ≈ 75 minutes of waiting alone** — an order of magnitude more than
the ~8 min of `age` sealing measured for the same volume.

The batch **contract is already bulk-capable**: `POST /v1/messages` stores an
atomic, idempotent batch of 1..1000 under a single team-row lock with one
range sequence allocation, and the push side already frames 1000-wire batches.
So nothing on the wire or in the cloud ingest needs to change. The only defect
is the loop's fixed small page + inter-cycle wait.

## Where the backlog comes from (why a mode/flag is wrong)

A backlog is not just a first-connect event. It also appears with **no
`connect` and no restart**:

- first `connect` (upload local history / delete-reconnect re-upload) — push backlog
- a laptop closed for a month, travel, or a long network outage — pull backlog
  (other machines kept sending); the user just resumes `run`
- a `run` that **stayed up** through a long outage: each cycle's POST failed,
  and when the network returns the steady loop trickles the accumulation

A `--backfill` flag only helps the user who *knows* they have a backlog, and
first-connect is the path *everyone* takes — it must be fast by default. A mode
launched at `connect` misses the resume/outage cases; a mode launched by "`run`
measures at startup" misses the stayed-up-through-outage case. **The trigger
must be the backlog itself, measured every cycle** — which is the adaptive form
below. It subsumes every case above with one rule.

## Decision: a two-stage page policy within `run` (not a separate mode)

`run` adapts by cadence, driven by whether the last push page **saturated**
(a full page was prepared):

- **steady** — the current behaviour, **unchanged**: prepare a **100** push
  page, then wait `interval`. This is where the loop sits when there is no
  backlog.
- **catch-up** — after a steady page saturates (100 candidates prepared, so
  backlog may remain), the next cycles prepare a **1000** push page with **no
  inter-cycle wait**, back-to-back, until a cycle's push page comes back
  **short** (fewer than the page size), which means the backlog is drained and
  the loop returns to steady.

This is a two-stage page policy, not a numeric hysteresis band: "saw a full
steady page → probe with a large page; the large page came back short →
drained." There is no backlog count and no enter/exit threshold to flap
around. One honest consequence, stated plainly: if the backlog is **exactly**
one steady page (100, remainder 0), the loop runs **one extra catch-up cycle**
that finds nothing — a single safe probe, not a defect.

Because "steady" is byte-for-byte today's loop, the low-latency steady role is
never sacrificed. Catch-up only *adds* a fast path while a backlog exists.

### (1) It's a PUSH-cadence problem; pull already self-drains

Grounded in `cycle()` (`remote-sync.mjs:1273-1343`): a cycle **pushes one page**
of up to `limit` candidates, but its **pull side already drains to exhaustion**
— an inner `for(;;)` pages `GET /v1/messages` until `has_more` is false with no
inter-page wait (`if (!page.has_more) break;`, :1342). So a machine resuming
after a long gap pulls the whole backlog in the first cycle regardless of
cadence; **pull is not the 75-minute problem.** The wait bites only on the
**push** side, which sends a single `limit`-bounded page per cycle. So the
adaptive decision is about the push cadence, and — usefully — this confirms the
`--interval` reasoning below: during catch-up the loop is moving real data, not
empty-polling.

### Pull page size (separate from the wait decision)

Pull doesn't wait, but its **page size** still matters: 90k of pull backlog at
100/page is ~900 round-trips (~68 s at 50–100 ms each) vs ~90 at 1000/page
(~7 s). This bites exactly when push-saturation would *not* fire — a read-only
machine that was closed for a month has a large pull backlog and nothing to
push (an actually observed case, and a common one).

Two ways to get the bigger pull page there:
- **(proposal)** a second signal — raise the pull page when `current_seq −
  transport_cursor > page_size` (both already in hand: `current_seq` at :1276,
  `transport_cursor` at :1305), keeping the *wait* decision on push saturation
  alone.
- **(simpler, leaning this way)** just give pull a **large page size
  unconditionally**. A big page cap is harmless in steady state — when only a
  few messages exist the page returns a few and `has_more` is false after one
  round-trip — and optimal under backlog. This needs **no pull-backlog signal
  and no mid-cycle computation**, and keeps "one signal for the wait." The only
  change is decoupling the pull page cap from the push `limit` (today both use
  the same `limit`); to confirm contract-safe at implementation (the server
  caps at its own max; page validation uses the pull limit).

**Decided: unconditional large pull page** — simpler than a second signal, and
harmless in steady state. Two implementation traps found in
the real code, both mandatory:

- **Trap 1 — validation also reads `limit`.** The pull request
  (`...&limit=${limit}`) and its page check (`page.messages.length > limit
  → "pull page is invalid"`, ~:1308-1310) read the *same* `limit`. Decoupling
  the pull cap must switch **both** to the pull limit together; fixing only the
  request makes a legitimate 1000-message page throw. Normal tests carry no
  backlog so they never receive a large page and never hit this — **a test that
  creates backlog and asserts a large page is accepted is required**, not
  optional (an untested path is as good as absent — the device-flow lesson).
- **Trap 2 — explicit `--limit` caps pull too.** The `min(1000, N)` ceiling we
  set for push applies to pull as well: the user's motive (request size, memory,
  slow-link timeout) is *stronger* for pull, which holds and evaluates a whole
  page. So only the **default** lets pull go to 1000; an explicit `--limit N`
  caps pull at `min(1000, N)`. Also confirm what `readStateCycle(config, limit)`
  (~:1343) expects its limit to mean, and route the decoupling through it
  consistently.

### The saturation signal (no driver change)

The signal already present is **page saturation**: `prepare` returns up to the
current push page size of candidates; `candidates.length === pushLimit` (and the
write profile is eligible) means at least a full page was available, so more
remain. `candidates.length < pushLimit` means this cycle pushed everything
outstanding — push is drained. No new field or round-trip is needed. (An
exactly-full page proves "a full page was available," not strictly "more than a
page remains" — hence the one safe extra probe cycle noted above.)

There is deliberately **no numeric backlog count and no enter/exit threshold**.
The two page sizes (steady 100, catch-up 1000) are what differ between the
stages; the transition is decided purely by "did the push page fill?", which has
no boundary to oscillate around. If a future driver ever exposes an exact
un-sent count, that is a separate design change — not part of this one; do not
carry a second, numeric rule alongside this one.

### How it returns

The **same `run` process** switches cadence — there is no separate process or
mode to launch or exit. A saturated steady page moves it to catch-up (1000-page,
no wait); the first short catch-up page moves it back to steady (100-page,
`interval` wait). A later burst that fills a steady page moves it to catch-up
again, automatically. One loop, two stages.

## Backoff is independent of cadence (required)

The current loop's `interval` wait serves **two** roles: the steady poll
cadence *and* the only backoff after a retryable failure
(`remote-sync.mjs:1565-1572` — a caught retryable error falls through to the
same `setTimeout(interval)`). There is no independent backoff.

Naively "no wait during catch-up" therefore hot-loops on failure: during an
outage every cycle throws (fetch failure is retryable) before it can observe a
short page, so catch-up stays engaged with zero wait → a tight retry loop
against connection-refused / DNS failure. Worse, `429` and `503`
are retryable too, so catch-up would hammer a server that is explicitly asking
us to wait. The very scenario this design exists for (a `run` sitting through a
long outage) is the one that would burn battery/CPU and then stampede the
server on recovery.

Fix: **separate the failure backoff from the cadence.**

- The post-cycle delay is chosen by outcome, not by cadence alone:
  - **cycle failed (retryable):** always wait, in *either* cadence —
    **exponential backoff** from a small base (e.g. 1 s) to a cap (e.g. 60 s),
    tracked by a consecutive-failure counter kept separately from the cadence
    state. This is the core fix and needs nothing new from the transport.
    *Enhancement (separate, optional):* the fetch layer does **not** currently
    surface a `Retry-After` header (it isn't parsed anywhere in
    `remote-sync.mjs` today), so honoring `Retry-After` on `429`/`503` means
    first capturing that header onto the error, then using `max(Retry-After,
    backoff)`. Call it out as its own small change, not assumed behavior.
  - **cycle succeeded, catch-up, made progress:** no wait (the fast path).
  - **cycle succeeded, steady:** the `interval` wait, as today.
- A successful cycle resets the failure counter to zero.

So "catch-up removes the wait" means **only between successful, progress-making
cycles**; a failure always backs off regardless of cadence. This keeps the
fast path fast while a machine that can't reach the server backs off politely
instead of spinning.

## `--limit` and `--interval` are treated differently (their purposes differ)

- **`--limit`** bounds a real per-request cost (memory, request size, timeout
  risk on a slow link). An explicit value is a **ceiling**: catch-up pages at
  `min(1000, N)`, never above the user's N; only the default (100) is raised to
  1000. (`args.limit` is `undefined` when unset — `Number(args.limit ?? 100)`,
  :1546 — so default vs explicit is distinguishable.)

- **`--interval`** exists to avoid **empty-polling the server when there is
  nothing to do**. During catch-up every cycle moves real messages, so that
  purpose doesn't apply. So catch-up removes the inter-cycle wait **regardless
  of whether `--interval` is default or explicit**; the interval governs only
  the steady cadence. Three reasons this is right (revised on review):
  1. the interval's reason-for-being (don't hammer on empty polls) is absent
     while real data flows every cycle;
  2. treating an explicit value as "intent" breaks here — systemd units and
     launch scripts routinely write every flag explicitly even at defaults, so
     a unit carrying `--interval 5` would get *zero* catch-up benefit and
     silently regress to 75 min;
  3. if bandwidth is the worry, an interval doesn't help — total bytes are
     unchanged, and a metered/slow link is limited by total volume / transfer
     rate, not by inserting waits.

- **Failure backoff is independent of all of this** (previous section): after a
  retryable failure the loop always waits, in either cadence.

## The other four points (mapping accepted on review)

- **Server range sequence allocation** — already the contract shape: `POST
  /v1/messages` locks the team row once and allocates a sequence *range* for the
  new IDs in that batch (`UPDATE teams SET team_seq = team_seq + $count
  RETURNING`), never per-message. This is a cloud-ingest implementation
  requirement to pin with a test, not a contract change.
- **Large-batch accept** — no new API. The cloud ingest implements the existing
  `POST /v1/messages` (atomic, idempotent, 1..1000); catch-up simply sends full
  1000 batches back-to-back.
- **Resumability / no whole-batch loss** — each 1000 batch is one transaction
  and idempotent: an interrupted or failed batch is re-sent next cycle and
  absorbed as duplicates (identical UUID+payload → `duplicate` ack with the
  original `server_seq`). Worst-case loss is one in-flight batch (≤1000),
  bounded and re-sent; the existing manifest/backfill progress is unchanged.
  **Verify the failure path is actually exercised** (a mid-catch-up batch
  failure re-sends the same range and converges) — a test, not an assumption.
- **Progress** — decided on post-wait numbers: with the wait removed, sealing
  dominates (~5 ms/msg measured → ~8 min for 90k; 2–4× on slower/Windows
  hardware), so a progress indicator over batches acked is enough; no
  background/suspend-resume requirement. Seal parallelization is deferred until
  the separated path is measured (and the Windows measurements land).

## Scope / ownership

- OSS-side change to `remote-sync run` only → `integration/remote`. Steady-state
  behaviour and the wire contract are untouched.
- Cloud ingest (`POST /v1/messages` with range allocation + the pre-connect
  capacity gate) is the separate cloud-side task and needs no contract change.
- Pre-connect capacity estimate/reservation (refuse before starting if the
  history won't fit the plan) remains the backfill start gate as previously
  decided.
