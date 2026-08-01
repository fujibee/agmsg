# Remote connect onboarding design

> **SUPERSEDED.** The onboarding this describes was replaced by
> [`docs/design/remote-sync.md`](../remote-sync.md), which states the replacement
> from its own side. Kept as design history: the reasoning here is why the
> current shape is what it is, and the findings it records were closed rather
> than dropped. Do not build to it.

**Status:** implemented dogfood design — §1/§1a-§1c/§8's four key commands (generate/show/
import) and §0-§7's connect/status/disconnect/doctor are approved and
implemented (this PR). `key rotate` remains NOT READY — see §8 — and is
explicitly out of this PR's scope pending its own follow-up design/review
pass. `key request`/`approve` (device-pairing key delivery) has moved to
`docs/design/ref/device-pairing.md`, where its open findings are addressed; it
is designed but not yet implemented, and is not in this PR either.
**Date:** 2026-07-21 (implementation landed 2026-07-23)
**Owner:** @fujibee

This is an editable product and CLI design, not an architecture decision
record. Persistent binding, credential, key-custody, and synchronization
semantics are recorded in the relevant ADRs and versioned specifications.

## Context

The landing page commits to: *"Connect a team. One token links a team to your
cloud org. That is the whole setup."* This design turns that promise into an
actual CLI (and companion cloud-console) design, sitting on top of the
Stage-1 remote sync ABI
([specification](../../spec/ref/stage-1-remote-sync.md), draft PR
#450, `storage_sync_prepare_push` / `storage_sync_reconcile_push` /
`storage_sync_apply_pull`) and the rebased storage-axis driver contract
([ADR 0003](../../adr/0003-storage-axis-driver-abi-and-scope.md)).

This was an **interface addition** (a new command surface, a new
credential storage location, a new team-config field), reviewed and
approved by the maintainer before implementation began, per standing
policy. The implementation went through several rounds of adversarial
security review (see References) before landing.

Seven questions were posed and are answered below: (1) command shape, (2)
token shape, (3) what "connect" actually does, (4) idempotency, (5) failure
UX, (6) where E2EE's key-bootstrap step attaches, (7) the cloud-console
side of the same flow. Cloud onboarding defaulting new teams to end-to-end
encryption (`age-v1`, already an approved profile) added an eighth: (8) the
key management commands (`generate`/`show`/`import`) that step needs,
folded into this same document/review pass rather than a second one. A
review pass afterward settled a foundational point stated first, as §0:
`connect` is scoped to exactly one team, never a machine or an org.

## Decision

### 0. Connection unit: team, not machine or org

**Settled during review, stated up front because it shapes every other
section:** `connect` operates on exactly one team per invocation, never a
machine-wide or org-wide binding.

- **A token is team-scoped.** It is minted for one specific cloud team and
  the exchange response identifies that team; it is not a credential that
  lets the CLI pick from a list. Connecting N cloud teams to one machine
  means running `connect` N times with N distinct tokens — never one token
  that fans out to multiple teams.
- **Org-wide tokens (the console's admin/automation token tier) are
  explicitly not part of this onboarding flow.** They exist for
  provisioning automation, not for `agmsg remote connect`. Reasons this
  ADR treats that as a hard boundary rather than a convenience to add
  later: (a) blast radius — a leaked team token compromises one team; a
  leaked org token compromises every team in the org, and the "one
  argument you can paste anywhere without much thought" ergonomics this
  ADR designs for a team token are the wrong ergonomics for something with
  org-wide reach; (b) it doesn't compose with §8 — a key is a *team* key
  (one `age-v1` epoch snapshot per team), so an org-wide connect would have
  no single team to attach the key-bootstrap step to.
- **This mirrors two decisions already made elsewhere in this design, not
  a new one invented for its own sake:** the per-team active storage
  driver switch (§3.5) and the per-team encryption key (§8) both already
  assume "team" is the unit that gets bound/keyed/switched independently
  of every other team. Making `connect` itself team-scoped is the
  connection-establishment step lining up with the unit the other two
  already committed to — a machine-wide or org-wide `connect` would have
  left those two either unreachable (which team does an org-wide binding
  switch the driver for?) or requiring their own separate team-selection
  step immediately after, duplicating work `connect` should have done
  once.

### 1. Command shape

**Role split (settled during review): the OSS CLI is a generic client with
no commercial endpoint baked in. It never assumes or defaults to any
particular server — `<endpoint>` is a required argument, always.** The "one
token, one paste" experience the landing page promises is delivered by the
**hosted console generating a complete, ready-to-paste command** (endpoint
included) — see §7. The CLI's job is to be correct and endpoint-agnostic;
the "feels like one token" UX is a hosted-onboarding presentation concern
layered on top, not a CLI default.

**Pinned format (reconciled with the cloud-console side's own proposal):**
`--endpoint` is a **named flag**, not a bare positional, specifically
because a labeled flag can never be mistaken for the token even out of
context (a support screenshot, a truncated paste, re-typing from memory) —
stronger on "hard to get argument order wrong" than two adjacent bare
positional strings, which was this draft's original proposal.

**Decision (interface addition, added after review — the pairing token is
a bearer secret and gets the same discipline as §3.4's session credential
and §8's key material): the bare-positional `<token>` is kept only as a
legacy, warned option; `--token-stdin` (reading the token from stdin/an
inherited FD, reusing §8's sealed-fd handling rather than a new mechanism)
is the mandatory path for provider tooling spawning `connect`
programmatically.** A positional argument is visible in `ps`, shell
history, and any tool/agent transcript that logs invocations — acceptable
for a human manually pasting a token copied from the console (Path B,
§1a), not for an automated handoff. The positional form stays available
and simply warns on stderr, since Path B's console-copy-paste UX (§7)
genuinely is a human typing/pasting a visible argument.

**`doctor`** (adopted into v1 scope): a standalone, read-only,
always-safe-to-run command that surfaces the same preflight checks
`connect` runs internally (currently just §8's `age`-binary-presence
check) — no token, no state change, usable whether or not the team is
already connected. Exists so console/support flows can point a user at
one command to diagnose a missing dependency without a real `connect`
attempt.

Self-hosted and hosted use the **identical shape** — only the `<url>` value
differs, never the command's structure, which is the third criterion this
format was chosen against.

**`<team>` is a local-name override, not a team selector.** The connection
unit is the **cloud team the token itself refers to** (§0 above) — the
token already answers "which team", so `<team>` on `connect` is only for
naming the *local* team the binding attaches to, and defaults to the cloud
team's own name (returned in the exchange response) when omitted. Supply
it only to bind under a different local name (e.g. an existing local team
already has that name for an unrelated reason). `status`/`disconnect`'s
`<team>` is the ordinary local-team-name argument every other command in
this codebase already takes — no special resolution logic, no
multi-team-disambiguation prompt to design.

### 1a. Onboarding paths: agent-driven (Path A) vs. console-driven (Path B)

**Boundary: this is provider tooling's design, not this OSS repo's
implementation scope. This design names no specific product** — only the
contract: some **provider tooling** (a vendor CLI, or a vendor console)
owns login, org/team management, and pairing-token acquisition, then
simply **calls this repo's unmodified §1-5 `connect`**
(`scripts/remote.sh connect --endpoint ... --token-stdin`) with the token
it obtained — the same shape as `gh`/Tailscale's CLIs, where a
provider-specific tool handles auth and a separate protocol client just
receives a credential. **This OSS repo's interface does not change at
all** — `connect` still just receives a bearer token exactly as §2-§3
already specify; it has no awareness of whatever login flow happened
upstream of that token, and doesn't need to. A **self-hosted server's own
admin command**, issuing a token directly with no "login" concept at all,
is exactly as valid a token-issuing entity as any hosted provider tooling
— this design treats the two as peers, not a primary path and a fallback.
The design below is kept here as **context for why the boundary sits
where it does**, not as OSS-implemented scope:

- **Path A (existing agmsg users, agent-first):** the human's agent runs a
  device-authorization login (RFC 8628-style) on the human's behalf; the
  human's only action is **one browser-side click to approve** (§1c —
  the entire credential boundary). Org/team select-or-create, `connect`,
  and key generation follow automatically. A second device joining the
  same team goes through the same login, then `key request`, and the
  human manually carries the resulting confirmation code to the first
  device to `approve` it (`docs/design/ref/device-pairing.md`, designed but
  not yet implemented).
- **Path B (new users, console-first):** console-driven, building on §7's
  existing copy-paste block — the block leads with instruction text meant
  to be pasted to an agent, with the raw shell command as a secondary
  form for a human running it directly.
- **Single-path presentation rule:** the CLI/console never shows both
  paths at once — which one is offered is decided by local state (an
  existing agmsg installation → Path A; a genuinely new user → Path B).
  Presenting both simultaneously was an explicit review finding to avoid.
- **Convergence:** both paths drive the *same* underlying state machine —
  login → select/create → connect → key — which is exactly §3's connect
  flow underneath, just reached through two different front doors.
  Interrupting partway through is expected and supported via a resume
  token, so a half-completed flow picks back up rather than restarting
  from scratch.

### 1b. Endpoint discovery (`.well-known`)

**Same boundary as §1a: this moves entirely to provider tooling, out of
OSS scope.** A domain-to-endpoint discovery step only matters upstream of
the login flow §1a now owns; this OSS repo's `connect` always takes an
explicit `--endpoint` (§1) and never resolves one itself. Kept below as
the hardening list provider tooling needs to satisfy, not as an OSS
implementation task — every item is a concrete finding from adversarial
review, not a nice-to-have:

- IDNA-normalize the input domain and **explicitly display the punycode
  form** — never silently render only the Unicode form a homograph could
  spoof.
- **No fuzzy/auto-corrected domain matching** — a typo'd domain is a hard
  failure, never "did you mean...".
- Discovery `fetch` **disallows redirects** (or, at most, same-origin
  redirects only).
- Strict limits: response size cap, `content-type` allowlist, strict JSON
  parsing (no lenient/tolerant parsing), bounded caching.
- The resolved API endpoint defaults to **same-origin HTTPS**.
- **Cross-origin delegation**, if ever allowed, requires: the delegated
  origin shown explicitly on *both* the CLI and the browser approval
  page, an explicit human confirmation of the delegation itself (separate
  from the main approval), and the response's `issuer` field matching the
  originally-entered origin.
- The discovery URL itself may carry **no userinfo, query, or fragment**.
- **SSRF protections**: reject loopback / private / link-local / metadata
  IP ranges and guard against DNS rebinding, in hosted/default mode. Self-
  hosted setups get an explicit opt-out flag — this is not available by
  default.
- **First-connect pinning**: `(origin, api, server_instance_id)` is
  durably pinned the first time a team connects. Any later mismatch on
  any of those three is a **hard fail**; changing them requires an
  explicit, deliberate rebind operation, never a silent follow. A typo on
  the very first connect can't be caught cryptographically — which is
  exactly why the browser approval page (§1c) must display the issuer
  prominently at that moment, since that's the one point a human actually
  has a chance to catch it.

### 1c. Device-flow trust model: the terminal is not the trust anchor

**Same boundary: this is provider tooling's trust model to implement, not
OSS's** — kept here because it explains *why* §1a/§1b's design looks the
way it does, useful context even though this repo doesn't build it.

**Terminal output is never the basis for approval.** A prompt-injected
agent could display a fabricated URL or a fabricated code — trusting
whatever text an agent prints as the thing to approve would make the
whole device-flow login only as trustworthy as the agent's own integrity,
which is exactly the assumption this model must not make.

The actual trust anchor is the **browser approval page** (owned by
whoever owns the console/hosted-onboarding surface — not designed here,
same alignment-note pattern as §7). It must prominently display: the
canonical issuer/domain, the requesting client's name, the requested
scope, the target org/team, the flow's start time, and the device code
for the human to match against what their agent displayed — and it is
**deny-by-default**. Code matching is never skipped, even when a
`verification_uri_complete`-style URL (one that pre-fills the code) is
used — pre-filling is a convenience, not a reason to drop the check.

### Human-in-the-loop gates (cross-cutting — split across provider tooling and this repo's §8)

Four conditions, deliberately not automatable except through an
independent, already-authenticated channel (e.g. SSH, or a future QR
path — §8's forward-looking note). **Only 2-4 are this repo's concern —
gate 1 belongs to provider tooling (§1a-§1c), listed here for
completeness since all four were reviewed together:**

1. *(provider-tooling scope)* **Browser approval** — the boundary that keeps
   auth material from ever passing through the agent at all.
2. **Carrying the pairing code** — manual, by design; this *is* the MITM
   defense (§8, `key request`/`approve`).
3. **Storing the key backup** — a human action, not something the CLI
   automates on someone's behalf (§8).
4. **Post-decryption bidirectional confirmation (SAS)** — added after
   review specifically closed the earlier one-directional-auth gap (§8's
   A2 finding): a one-way code alone cannot stop a fake team-key
   injection from an attacker posing as a legitimate sender, so both
   sides must independently derive and display the same
   post-decryption confirmation string before the receiver commits.

### Secret hygiene (cross-cutting — applies to §1's pairing token, §3.4's session credential, and §8's key material alike)

- **Never in stdout, argv, or environment variables** — these leak into
  agent transcripts, shell history, and `ps` output respectively, none of
  which this design can assume are private. This now explicitly includes
  the **pairing token itself** (§1's `--token-stdin` correction) — it is
  short-lived and single-use, but still a bearer secret while it's live,
  and gets the same treatment as the longer-lived session credential and
  key material rather than an exception for being "just a token."
- Secrets pass between the CLI and its own subprocesses via an
  **internal file descriptor**, sealed, never as a printed or logged
  value — the same mechanism §1's `--token-stdin` reuses rather than
  inventing a second one.
- `key show --reveal-secret` requires an interactive human TTY plus an
  explicit typed confirmation (§8, unchanged) — and is **refused
  outright when invoked in agent mode**, full stop, no override.
- `key approve` (§8) **never displays key material at all** — structured
  redaction, not "redact unless asked."
- Nine distinct leak paths are named individually here so none get
  silently missed by an implementation that only thinks about the obvious
  one: (1) a reveal command's own output as captured by a tool-result
  channel, (2) session transcripts / shell `xtrace`, (3) shell history or
  `argv` (visible via `ps`), (4) environment variables, (5) debug-mode
  HTTP logging, (6) exception messages or stack traces, (7) the system
  clipboard, (8) backup/export pipes, (9) `approve`'s own log output.

### Command surface across install paths (decided)

There are multiple ways this codebase gets installed, with more
plausibly coming: `install.sh` directly, `npx agmsg install`, a possible
future default via the separate skills-CLI effort (`#201` — not this
architecture decisions to decide), and an existing CC-plugin form. A bare PATH shim in
`install.sh` only covers the first case, so it's rejected. **Decision:**
the npm bootstrapper (the existing `agmsg` package) gains subcommand
passthrough, so `npx agmsg remote connect ...` works identically
regardless of install path or `$PATH` state, guiding the user through
install if it isn't present yet. A per-install-path shim matrix was
considered and rejected as unnecessary once the bootstrapper covers every
path uniformly. Leading with agent-instruction text (§1a/§7) over a raw
shell command further reduces how often a human-facing literal command
needs to be shown at all — it doesn't replace the bootstrapper decision,
it just shrinks how often the question comes up.

This is separate from §8's internal-dispatch correction
(`scripts/key.sh <verb>`, not a bare `agmsg key <verb>`) — that's about
which script a slash command invokes internally; this section is about
what a human types directly into a terminal.

### 2. Token shape

The token is not the long-lived credential — it is a short-lived,
single-use **exchange code** that the CLI POSTs to `<endpoint>` to receive
back the actual session credential plus the team/org binding
(`server_instance_id`, `remote_team_id`, `protocol_version`, capability
document).

Considered and rejected: **encoding the endpoint inside the token itself**
(e.g. `<base64url(endpoint)>.<code>`), which was the original recommendation
before review settled that the CLI must not carry any endpoint assumption,
implicit or encoded. Beyond that settled point, embedding still has the
same independent problem: it reintroduces a second argument's worth of
information into one string a human has to copy-paste correctly, with no
visible seam to sanity-check ("does this token point at the URL I
expect?") — a copy-paste truncation or a substituted token is
indistinguishable from a valid one until the exchange call fails or
(worse) succeeds against the wrong server. A separate, visible `<endpoint>`
argument is safer on both counts.

The token itself: opaque, single-use, short TTL (recommend 15 minutes —
long enough to paste from a browser tab into a terminal, short enough that
a token pasted into Slack/a ticket by mistake is worthless soon after).
Format is an implementation detail for whoever builds the exchange endpoint;
the CLI treats it as an opaque string it never parses, matching the "opaque
to core" principle ADR 0003/0005 already established for cursors and wire
IDs.

### 3. What "connect" does

1. `remote.sh connect --endpoint <url> <token> [<team>]` — `<team>`, if
   given, is only the local-name override (§0/§1); it is never sent to
   `<url>` and never used to pick which cloud team gets connected.
2. POST the token to `<url>`. This is the **only** network call that
   can fail before any local state changes — see §5. The token alone
   identifies the cloud team (§0) — there is nothing else to disambiguate.
3. On success, the response carries: a session credential (the actual
   secret used for subsequent sync calls), a **`credential_id`** (a
   stable, non-secret identifier for *this specific device's* binding —
   distinct from the secret value itself; see step 4 and §4's revoke
   note), `server_instance_id`, `remote_team_id` (the cloud team's
   identifier), a human-readable cloud team name (used as the local
   team's default name when `<team>` was not given), `protocol_version`,
   and the capability document (per the Stage-1 specification's
   `GET /v1/capabilities`
   shape: `accepted_envelope_versions`, `write_allowed_ciphers`,
   `policy_revision`, `effective_from_seq`, `max_blob_bytes`).
4. The **secret is written to an engine-side credential store, never to
   `teams/<team>/config.json` or any other binding file that gets read,
   `cat`'d, or diffed as part of normal operation.** Concretely: a new file
   per team under the skill's own state directory, e.g.
   `~/.agents/skills/agmsg/run/remote-credentials/<team>.json`, created
   `0600`, outside the git-trackable/config-diffable surface — the same
   `0600`-plaintext-file mechanism §8 settles on as the *default* for the
   E2EE key too (not an OS keychain — see §8's "Key storage" for why),
   since both this credential and the age identity must be readable by an
   unattended background process with no TTY to prompt against. The
   secret itself is an **opaque bearer string** — the CLI never parses,
   decodes, or interprets its structure, mirroring §2's stance on the
   connect token (it is *not* the same value: the token is single-use and
   spent during exchange; this credential is the longer-lived secret used
   for every sync call thereafter). The **binding** (server_instance_id /
   remote_team_id / `credential_id` / protocol_version / capability
   snapshot / connected_at) is a separate, secret-free record — this is
   the ABI condition stated in the task: binding-json holds identifiers,
   never auth material.
5. The team's active storage driver is switched to the sync-capable
   (`capabilities=stage1-sync`) driver for that team specifically — this is
   a **per-team** setting, not the machine-wide `storage` config key
   `docs/spec/driver-interface.md` §4 currently describes. That per-team
   override did not exist before Stage-1 sync; this design's implementation
   will need a small, additive change to how the active driver is resolved
   (per-team lookup falling back to the machine-wide default), not a
   contract change to the driver ABI itself.
6. `remote.sh connect` prints a short human-readable confirmation (team
   name, org name from the capability/exchange response, "connected") —
   no secret, no raw token, ever echoed back.

### 4. Idempotency

- **Re-running `connect` with the same token** (before it expires/is
  consumed): the exchange endpoint is expected to be idempotent for a
  short window (mirrors the sync ABI's own "durable reserve, retry-safe"
  principle) — the CLI does not need special client-side handling beyond
  "the call either succeeds again or reports already-consumed", and either
  outcome is safe to surface as-is.
- **Re-running `connect <newtoken>` on a team that is already connected**:
  refused by default with a clear message naming the existing binding
  (org/team, connected_at) and pointing at `disconnect` first — mirrors
  this codebase's established pattern of refusing a silent overwrite and
  offering an explicit escape hatch (`send.sh`'s roster guard, `join.sh`'s
  rename-tombstone guard). Add `--force` to intentionally rebind (e.g.
  moving a team to a different org) — same shape as those two.
- **Multiple teams**: one token per team (§0) — connecting N cloud teams
  to one machine is N separate `connect` invocations with N distinct
  tokens, never a single fan-out. Each team's binding and credential file
  are fully independent; connecting team B never touches team A's
  binding, driver selection, or credential file. `remote.sh status` with
  no `<team>` lists every locally-known team's connection state in one
  pass (not just the one team just connected), since "what's connected
  right now" is exactly the kind of thing worth seeing in aggregate.
- **`disconnect`**: removes the per-team driver override (falls back to
  local-only), deletes the credential file, and marks the binding record
  disconnected (kept, not deleted outright, so `status` can still show
  "was connected until <time>" — useful for debugging a "why did my
  messages stop syncing" report) rather than silently vanishing all trace.
  **Server-side revoke, ordered as: revoke attempt first, local cleanup
  always.** Local deletion of the credential file alone does not stop the
  credential from continuing to authenticate server-side — the same "one
  action alone isn't enough" gap already called out for keys in §8's
  incident-response note, restated here for the sync-credential side of
  the same story. `disconnect` therefore first calls a server-side revoke
  keyed by `credential_id` (§3.3/§3.4) — never the secret value itself.
  If the revoke call succeeds, proceed to local cleanup as above. If the
  server is unreachable, **still perform local cleanup** (a user must
  always be able to locally disconnect regardless of network state) but
  print an explicit warning: "Local state cleared, but the server could
  not be reached to revoke this credential — if this device may be
  compromised, revoke it from the console/admin side directly." The
  revoke endpoint's own wire shape is a server-side implementation detail
  this design does not own (mirrors §3.2's stance on the exchange endpoint
  itself) — this design only fixes that `disconnect` must attempt it, keyed
  by `credential_id`, in this best-effort order.

### 5. Failure UX (local-first, doesn't break)

- **`connect` itself, server unreachable**: fails loudly and immediately,
  before touching any local state (step 2 in §3 is the only point of
  failure that can happen before any write). Nothing is half-connected.
- **Already connected, server later unreachable**: this is exactly the
  case Stage-1 sync's local-first design already exists for — sends and
  reads keep working against the local store; the sync client's own
  polling/retry loop is what's degraded, not agmsg itself.
  `remote status <team>` surfaces this plainly (e.g. "connected, last
  synced 4m ago, N messages pending push" vs. "connected, in sync") so a
  user who notices something feels stale has one command that tells them
  whether it's a sync problem or a "nobody's replied yet" problem — never
  a scary error, never a hang.
- **Capability mismatch discovered later** (e.g. org admin tightens
  `write_allowed_ciphers` after connect): surfaced via `status`, not a
  crash on the next send — a send that would violate the current policy
  queues locally with a clear reason rather than being silently dropped or
  blocking the caller.

### 6. E2EE insertion point (reserved, not built)

**Update: cloud onboarding now defaults new teams to E2EE (`age-v1`, approved
profile — see `docs/spec/ref/age-v1-profile.md`), so this is no longer a future
placeholder — it is concretized below and in §8.** The `age-v1` profile
itself (envelope framing, recipient-set epochs, the multi-writer cutover
protocol) is already pinned; this design only covers the **onboarding-time**
slice of it — generating or importing the *first* key for a device, not
rotating keys across an already-multi-writer team (see §8's explicit scope
line).

- Step 3.3 (reading the capability document) is exactly where the
  "this org requires encryption" branch lives: if `write_allowed_ciphers`
  excludes `none`, `connect` pauses **after** the token exchange and
  **before** "switch driver to remote" to run the key-bootstrap sub-flow —
  §8 gives its exact shape. If a key already exists locally for the team
  (imported ahead of time via `agmsg key import`, or generated on a
  previous run that was interrupted before the driver switch), the pause
  is skipped and connect proceeds straight through.
- The credential store introduced in §3.4 is the same mechanism the
  private age identity lives in: one per-team, per-epoch `0600` plaintext
  file, one storage mechanism built once for both the sync session
  credential and the encryption key — not two. See §8's "Key storage" for
  why this is a plain file by default rather than an OS keychain.
- `remote status` prints a capability summary (§5); it also reports
  whether a local key is present for the team's current cipher policy
  (e.g. "encryption: age-v1, key present" / "encryption: age-v1 required,
  **no local key** — run `agmsg key generate <team>`"), so a
  half-bootstrapped state (connected, driver not yet switched because the
  key step was skipped or interrupted) is always visible, never silent.

### 7. Cloud console side (token issuance) — this is where "one token" lives

Since the CLI itself always requires an explicit `--endpoint` (§1), the
"whole setup is one token" experience is **entirely a hosted-onboarding
presentation choice**, not a CLI behavior: the console generates and shows
the **complete command line**, endpoint and token both already filled in
— e.g. `agmsg remote connect --endpoint https://api.example-cloud.invalid
abcd1234 --team myteam` — as one copy-paste-able block. The user
experiences "paste one thing"; the CLI underneath still just took ordinary
arguments it never defaulted.

For the CLI flow above to make sense, the console needs a **"Connect a
team" screen** that:

- Lets an org admin pick/name the team being connected (or create one) and
  press a single "Generate connect command" action (not just "generate
  token" — the deliverable is the full command, per the role split above).
- Displays the **generated command** (not the bare token) as a **one-time,
  copy-once** block (shown once, reconfirmed with a "copy to clipboard",
  not retrievable again after leaving the page) — consistent with the
  token being single-use/short-TTL, and standard practice for any
  bootstrap-secret display.
- States the TTL plainly next to it ("expires in 15 minutes") so a user
  doesn't paste a stale value and get a confusing failure.
- After a successful exchange, the same screen (or a "Connected teams"
  list) shows: team name, connected-since timestamp, and last-sync status
  — the console-side mirror of `remote status`, so an admin doesn't need
  CLI access to see whether onboarding actually completed. **The natural
  row unit here is (team, `credential_id`), not team alone** — one
  `connect` call issues one credential to one device, and `age-v1`
  already anticipates multiple devices per team (multi-writer), so a
  team with 3 connected devices shows 3 independently-revocable rows,
  each with its own connected-since/last-active, not a single
  team-level toggle. A single device's own `remote status` (§5) only
  ever sees its own row — it has no visibility into other devices'
  `credential_id`s — so the full per-device list/revoke view is a
  console-only capability, since only the server holds the complete
  picture across every connected device. Revoking a row here is the
  server-side half of `disconnect`'s revoke step (§4) — the same action,
  triggered from the other side when the device itself is unreachable to
  run `disconnect` locally (e.g. lost/stolen hardware).
- When the target team requires encryption, the copy-paste block also
  carries a conditional "install `age` first if you don't have it" line,
  using the **exact** OS-specific install commands §8 pins in the CLI's
  own preflight message — this is the one piece of console copy this design
  does fix precisely (not layout, just this wording), since the whole
  point of pinning it is that the CLI's error text and the console's
  pre-emptive hint must never say two different things for the same
  missing dependency.
- Alignment note: the exact screen layout/copy, and the concrete hosted
  endpoint value it fills in, are a console (desktop-app-adjacent) surface
  this design has no authority over — that work belongs to whoever owns the
  cloud console/onboarding surface, reviewed independently. This document fixes
  only the **contract** the console and CLI must agree on: that the CLI
  takes `--endpoint <url> <token> [<team>]` with no default, what the
  token encodes/expires like, and what the exchange response shape is
  (§3) — not pixels, and not what the hosted endpoint's URL actually is.

### 8. Key management commands (`agmsg key ...`)

**Scope of this section: single-writer-per-team onboarding and rotation
only** — generating the very first key for a team, installing a key a
device already received out-of-band, or starting a new epoch when there is
exactly one active writer. The `age-v1` **multi-writer** cutover protocol
(rotating an already-established recipient set while more than one device
is actively writing, adding/removing a device from a team that already has
other active writers) is a separate, harder operational flow with its own
quiesce/fence/commit barrier (`docs/spec/ref/age-v1-profile.md`, "Multi-writer
cutover protocol") and needs its own design pass — not folded into any verb
below.

A new top-level noun, `key` — not nested under `remote` — because a team's
key is conceptually independent of the sync connection itself (it survives
`disconnect`/`connect` cycles; it's the thing a user reaches for with "show
me my key", not "show me my remote status").

**Decision: commands live in `scripts/key.sh` (dispatching on
`generate`/`show`/`import`/`rotate`), matching the `scripts/<name>.sh`
pattern every existing command uses** — there is no unified `agmsg`
dispatcher on `$PATH` today (the npm package's `bin` is an install-time
bootstrapper, not a runtime front-door; see the separate, undecided
`#201` front-door-CLI effort, which this design does not depend on).
`remote` (§1) already used this shape; an earlier draft of this section
didn't, and is corrected here to match.

**`key generate [<team>]`** — for the first device establishing a team's
encryption:

1. Generates a native X25519 age identity (per the `age-v1` profile) and
   its recipient.
2. Mints a `key_id` matching the profile's required shape
   (`[a-z0-9][a-z0-9._-]{0,63}`) — e.g. `epoch-<date>` — and creates the
   team's first epoch snapshot: `epoch_revision=0`, `writer_generation=0`,
   a single-recipient manifest (this device), `previous_snapshot_sha256`
   null.
3. Stores the private identity in the same per-team credential store
   `connect` already established (§3.4) — never in `teams/<team>/
   config.json`, never logged.
4. Stores the **public recipient** in a binding-scoped config record (not
   secret — safe to sit next to the rest of the team's remote binding).
5. Prints the recipient's fingerprint (a short, human-comparable digest)
   and a **mandatory-reading backup notice** — not a dismissible
   one-liner, stated plainly once at creation time: back the key up now
   (a password manager entry, never a dotfiles/git repo or other
   synced-by-a-tool location); there is no server-side recovery; losing
   the device means permanent, unrecoverable data loss for everything
   encrypted under this key; removing a device later does not revoke its
   ability to read history from before removal. These are the H7
   operational facts (`lost key = unrecoverable`, `no server-side
   recovery`, `removal does not revoke history`) — exact wording belongs
   in implementation-time usage docs, not repeated here.

**`key show [<team>] [--reveal-secret]`** — default (no flag): prints only
the **public** recipient and its fingerprint, safe to run routinely (e.g.
to compare fingerprints with a teammate over a separate channel — the H7
"fingerprint verification" step: two people read/compare the same short
string over a phone call or in person, confirming neither is looking at a
substituted key). `--reveal-secret` prints the private identity material
and requires an explicit interactive confirmation (typing a confirmation
phrase, not just accepting a `y/N` — this is the one place in the whole
flow a raw secret ever reaches stdout, so it should feel deliberately
harder to trigger by accident than the rest of the CLI).

**`key import <team> <identity>`** — for a device that already possesses a
private age identity obtained through a secure out-of-band channel (e.g.
handed off by an existing team member, or retrieved from wherever the
`age-v1` profile's "epoch authority" distributes it). Validates the
identity parses as a well-formed age identity, stores it in the credential
store (same as `generate` step 3), and — if the team's capability response
already carries an epoch snapshot for this team — verifies the imported
identity's recipient is a member of the current authorized manifest before
accepting it (fail closed: an identity that decrypts nothing useful for
this team is more confusing to discover later than to reject up front).
Does **not** itself create a new epoch or snapshot — that only happens via
`generate` (for a brand-new team) or `rotate` below.

**`key rotate [<team>]`** — starts a new epoch for a team **that has
exactly one active writer** (this device). Explicitly not a general
multi-device rotation tool (see scope note above and §8's own boundary in
Alternatives).

1. Generates a fresh X25519 identity/recipient and a new `key_id`
   (`epoch_revision` incremented, `writer_generation` unchanged — single
   writer, no cutover barrier needed).
2. **Never re-encrypts existing envelopes** (H1): every message already
   sealed under a prior epoch stays exactly as it is. Only messages sent
   *after* rotation use the new key.
3. The local keyring retains **all** prior epochs, not just the newest —
   needed to decrypt history, and because `age-v1` explicitly requires
   clients to retain authorized old identities (§ "Rotation and
   revocation are prospective").
4. Distribution in this (v1, single-writer) design is **manual**: `rotate`
   does not push the new key anywhere by itself. Sharing it with anyone
   else who needs to read new messages is a fresh `key show` / hand-off,
   the same manual step as initial onboarding (§8's `import`). Automated
   multi-device distribution is exactly the piece deferred to the future
   multi-writer design.

Two operational notes this design states explicitly rather than leaving
implicit, since they're easy to get wrong once and hard to notice:

- **New-member history visibility is a deliberate choice, not automatic.**
  Handing a newly-joined member only the *current* epoch's key (not the
  full keyring) means they can decrypt everything from here forward but
  nothing from before they joined — a legitimate, useful option for "new
  hires shouldn't see old history", but it only happens if whoever
  onboards them chooses to share just the latest epoch rather than the
  full keyring. `key show` should make it possible to select this (e.g. a
  future `--epoch <key_id>` scoping flag), but this design does not commit to
  that flag's exact shape — only that the choice must be possible and
  is not automatic.
- **Incident response is two commands, not one, and both matter.** If a
  device (and its stored key) is compromised, the response is `remote`
  credential revocation **and** `key rotate` together: revoking only the
  sync credential stops the compromised device from *pushing/pulling new
  traffic* but does nothing about a key it already copied being used to
  read messages obtained another way (a prior local export, a stolen
  disk); rotating only the key stops *future* messages from being
  readable with the old key but does nothing if the compromised
  credential can still reach the transport. A future incident-response
  doc/runbook should state this pairing explicitly, not leave it to be
  independently rediscovered during an actual incident.
- **Member removal requires rotation.** Because §8 already established
  that removing a recipient from a later epoch does not revoke its
  ability to decrypt *earlier* ciphertext, "remove a team member" is not
  a complete operation on its own — it must be paired with `key rotate` to
  actually stop that member's copy of the key from reading anything new.
  This should be a **documented requirement** (onboarding docs / a future
  "remove a member" runbook), not left as an inference a team admin has to
  make correctly under pressure. The cloud console's own member-removal
  UI guiding an admin through revoke-plus-rotate together is a natural
  future requirement for whoever owns that surface — referenced here as a
  dependency, not designed here.

**Preflight: `age` binary presence.** Before the key-bootstrap prompt
below runs at all — and only when the capability response actually
requires encryption — `connect` verifies the `age`/`age-keygen` binaries
are present on `$PATH`, since a device's very first `connect` is
plausibly its first-ever encounter with agmsg's encryption path. On
failure it stops with an OS-appropriate install command rather than a
silent no-op or bundled fallback. **Decision: this install-command text
must be pinned identically between the CLI's own message and the console's
copy-paste block (§7)** — exact wording is an implementation-time detail
(usage docs), but the two surfaces must never drift into saying different
things for the same missing dependency.

**Connect-flow integration** (concretizing §6's reserved insertion point):
once the `age`-presence preflight above has passed (or was skipped as
not required), when `connect`'s capability fetch shows
`write_allowed_ciphers` excludes `none` and no local key exists yet for
the team, `connect` pauses right there. **The default choice offered is
picked by whether the team's message stream is empty**, not left as an
arbitrary "generate is option 1":

- **Stream empty** (nothing has ever been sent to this team): defaults to
  **generate** — an empty stream is the strongest available signal that
  this device is plausibly the *first* one ever connecting this team, so
  generating a brand-new key is the common case.
- **Stream has messages already**: defaults to **import** — existing
  history is a strong signal that at least one other writer already
  established this team's encryption; generating a fresh, unrelated key
  here would silently create a second key with no relationship to
  whatever already-existing history is encrypted under the real one
  (exactly the accidental-divergent-writer scenario §8 already declines
  to auto-handle) — so the safer nudge is toward import.

The prompt offers three explicit choices — generate, import, or abort,
with the default pre-selected per the stream-state rule above (exact
wording is a usage-docs detail, not repeated here).

Choosing **abort** exits with no binding created and no driver
switch — the same "nothing half-connected" guarantee §5 already commits
to for the token-exchange failure case, extended here to a
user-initiated stop.

Choosing **import** when there's no key on hand yet is guided
in-line: "On another machine that already has this team's key, run
`agmsg key show <team> --reveal-secret` and paste its output into
`agmsg key import <team> <identity>` here."

**Key-loss edge case, stated explicitly rather than left implicit:** if
the only device that ever held this team's key is gone entirely — no
other machine has a copy, no backup was made per `key generate`'s
warning (§8) — there is nothing to import. The historical stream stays
permanently unreadable under the lost key; this is not a bug to work
around. The only forward path is `agmsg key rotate <team>` to start a
fresh epoch for messages sent from now on — it does not, and cannot,
recover anything encrypted under the key that was lost.

— then runs the corresponding `key generate`/`key import` sub-flow inline,
and only *then* continues to "switch driver to remote". If a key is
already present (imported earlier, or left over from an interrupted prior
run), this prompt is skipped entirely and connect proceeds straight
through — matching §6's "never silently half-connected" principle: the
team is not marked connected until both the binding *and* (when required)
the key exist.

**Key storage (default, and why)**

- **Default: a `0600` plaintext file, one per team per epoch**, in the
  same per-team credential store §3.4 already introduced (not a new
  location) — e.g. `~/.agents/skills/agmsg/run/remote-credentials/
  <team>/keys/<epoch>.key`, holding the raw age identity. This is the
  *only* default; there is no passphrase prompt and no OS-keychain path
  in v1.
- **Why not passphrase-protected:** both message decryption (inbox/history
  rendering) and the sync engine's own background push/pull loop must be
  able to read the key with **no TTY and no human present** — `watch.sh`
  and any cron/headless invocation depend on this. A passphrase-locked
  key either blocks forever waiting for a prompt that will never come in
  that context, or forces caching the passphrase somewhere else on disk —
  which is exactly the same exposure as not having a passphrase, with
  extra failure modes and none of the benefit.
- **Why not OS keychain by default:** the same background-access
  requirement rules it out — macOS Keychain / GNOME Keyring / etc. are
  bound to an unlocked login session, and agmsg's own background watcher
  routinely runs detached (a backgrounded tmux pane, an SSH session with
  no unlocked session behind it, a headless CI-like runner). Making
  keychain the default would turn "decrypt silently fails because the
  keychain is locked" into the common case for exactly the always-on
  background usage agmsg is built around — a strictly worse default than
  a plain file. Keychain integration remains a plausible **future,
  explicitly opt-in** hardening flag for a user who only ever runs agmsg
  interactively on a single desktop session with no background watcher —
  not something this document designs now.
- **Honest threat model:** on a single-user machine, protecting the key
  file alone is close to security theater — the key and the decrypted
  plaintext message history (and, in most setups, the local sqlite/jsonl
  store itself) sit on the same disk, under the same account. Anyone who
  can read that account can already read both; the `0600` bit only keeps
  out *other local accounts* on a shared machine, which is worth having
  but is not the real boundary. The actual protection is whole-disk /
  home-directory encryption (FileVault, LUKS, BitLocker) plus ordinary
  account hygiene — agmsg's E2EE model defends data in transit and at
  rest on a **compromised or untrusted server**, not against a
  compromised local account that already holds the key. `key generate`'s
  backup warning (above) and this threat-model note should be read
  together, not in isolation.
- **Re-confirmed: the server never holds the key, at any point.** The
  session credential (§3.4) and the age identity (this section) are both
  local-only by construction — the exchange/capability responses (§3)
  never carry key material, and no `key` subcommand ever transmits the
  private identity anywhere. This is not a new design decision; it is the
  literal definition of end-to-end encryption restated here because it is
  the one guarantee every other bullet above assumes.

**`key request` / `key approve` — device-pairing key delivery. Moved to
its own document: `docs/design/ref/device-pairing.md`.**

That design closes the four findings this section left open (the
confirmation code's grinding resistance, the request/delivery state
machine, `age-v1` policy-gate compatibility, and broadcast-stream
quarantine for non-receiver clients) and folds in the expiration
requirements added afterwards. The fifth finding, one-directional
authentication, was already closed by the post-decryption bidirectional
SAS in "Human-in-the-loop gates" above.

Pairing is now the **primary path for a second device**, with the recovery
key demoted to the no-surviving-machine case, so this is launch-blocking
rather than a follow-on track. The earlier `send`/`receive` draft that sat
here has been removed rather than kept as reference: it was explicitly
marked not-a-spec, and leaving a superseded flow inline next to a live one
is how the wrong one gets implemented.

What this section still owns, unchanged: `generate`, `show`, `import`,
`rotate`, key storage, and the connect-flow key-bootstrap prompt above.

## Alternatives considered

- **A single `agmsg connect <token>` top-level command** (no `remote`
  noun). Rejected: agmsg's existing top-level surface is entirely
  messaging verbs (`send`, `history`, `team`, `mode`, `spawn`...); `remote`
  as a noun groups three related, symmetric actions
  (`connect`/`status`/`disconnect`) the same way `delivery.sh` groups
  `set`/`status`, and leaves room for a future `remote reconnect` or
  `remote rotate-credential` without inventing new top-level verbs each
  time.
- **A default/hardcoded hosted endpoint in the OSS CLI**, with `--endpoint`
  only as an override. This was the original proposal; rejected during
  review — the OSS client must not bake in any particular commercial
  service as its default. `<endpoint>` is a required positional argument
  with no fallback, full stop; the "one thing to paste" UX is recovered
  entirely on the hosted-console side (§7), not by the CLI defaulting
  anywhere.
- **Encode the endpoint in the token** (see §2) — rejected there, on
  independent grounds (a substituted/truncated token becomes
  indistinguishable from a valid one).
- **Store the secret in `teams/<team>/config.json`** alongside the
  binding. Rejected: that file is read by many existing code paths (some
  of which log it, echo it, or hand it to `readfile()` in SQL contexts)
  and is the most-likely-to-be-pasted-into-a-bug-report file in the
  codebase. Secrets do not belong anywhere near it.
- **Machine-wide (not per-team) remote driver switch.** Rejected: the
  landing-page promise and the sync ABI's binding key are both team-scoped
  (`remote_team_id` is part of the binding tuple); a user with two teams,
  only one of which is an org team, should be able to connect exactly one.
- **Let `connect` accept an org-wide token** (connect to every team in an
  org in one shot, or select from a list). Rejected as the default path
  (§0): an org-wide credential's leak blast radius is every team in the
  org, not one — the wrong ergonomics for something meant to be pasted
  from a browser tab into a terminal without much ceremony. It also has no
  single team to attach §8's key-bootstrap step to. Org-wide tokens still
  exist for admin/automation tooling; they are simply not what
  `agmsg remote connect` accepts.
- **Nest key commands under `remote`** (`remote key generate`, etc.)
  instead of a top-level `key` noun. Rejected: a team's key outlives its
  connection state (disconnecting doesn't destroy it, and a key can exist
  before a first `connect` if imported ahead of time), so nesting it under
  `remote` implies a lifetime coupling that isn't real.
- **Fold single-writer key rotation into `key generate`** (regenerate =
  rotate). Rejected: generate and rotate have different preconditions and
  different failure modes (generate assumes no prior key; rotate assumes
  one and must not disturb ciphertext already sealed under it) — collapsing
  them risks an accidental overwrite of an existing epoch. Given its own
  verb instead (§8).
- **Fold multi-writer-onboarding into any of these four verbs** (e.g.
  having `key rotate` also "add me as a new writer to an existing
  multi-writer team"). Rejected: that path requires the full
  quiesce/fence/commit barrier the `age-v1` profile specifies for a
  reason — collapsing it into a single local command would either skip
  the barrier (unsafe: two active writers could straddle a cutover) or
  silently block/hang inside what looks like a simple local command. Left
  as an explicitly separate, future design; every command in §8 assumes a
  single writer per team.

## Consequences

- Positive: the OSS CLI stays a genuinely generic, endpoint-agnostic
  client — no commercial default to maintain, question, or explain away
  for self-hosted/enterprise users; the landing-page "one token" promise
  is still delivered, just entirely as a hosted-onboarding UX choice (§7)
  rather than a CLI default, which is the more honest place for a
  commercial-product promise to live anyway; reuses established codebase
  conventions (subcommand verb grouping, `--force` escape hatches,
  per-team scoping) instead of inventing new ones; leaves an explicit,
  named slot for E2EE onboarding without committing to its UI yet; keeps
  secrets out of every file that is already read/diffed/logged elsewhere.
- Negative: introduces a **per-team active storage driver** concept that
  the current spec (§4) does not have (today's `storage` config key is
  machine-wide) — a small, additive spec change, not a breaking one, but
  real work beyond "just call the three sync functions." Also: a
  self-hosted/OSS-only user's onboarding doc must now show the full
  `--endpoint <url> <token>` command explicitly (no default to omit),
  which is marginally more to write in docs/README than a bare-token
  example would have been.
- Neutral: the cloud-console screen itself, and the concrete hosted
  endpoint value, are explicitly out of this design's authority (contract
  only) pending review from whoever owns that surface.
- Neutral: `key generate`/`show`/`import` cover onboarding (first key,
  first device) only. Removing/adding a device from an already-multi-writer
  team, and any UI for the `age-v1` profile's quiesce/fence/commit
  rotation barrier, are explicitly deferred to a follow-up design — this
  design does not claim to have solved key rotation.

## References

- Builds on [ADR 0003](../../adr/0003-storage-axis-driver-abi-and-scope.md) and
  [Stage-1 synchronization specification](../../spec/ref/stage-1-remote-sync.md)
  (draft PR #450).
- [`docs/spec/ref/age-v1-profile.md`](../../spec/ref/age-v1-profile.md) (approved
  cipher profile, commit `eea3307`) — the key format, epoch model, and
  multi-writer cutover protocol §8 is scoped against.
- Internal adversarial design review, rounds 1 (sync gates A-G) and 2 (E2EE
  gates H1-H8) — the profile this design's §6/§8 defer to.
- Standing policy: any interface addition requires explicit maintainer
  approval of the design doc before implementation (this document).
- Implementation-time adversarial security review of `scripts/remote.sh`/
  `scripts/key.sh` (this PR): an initial 7-finding pass (B1-B7) and three
  delta re-review rounds (R1-R5, D1-D5, E1-E3) — covering secret-argv
  leakage, transport/response validation, connect transactionality and
  idempotent resume, and the decision to hold `key request`/`approve` and
  `key rotate` back as NOT READY. Cleared with no blocking findings as of
  this PR.
