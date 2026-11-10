# Antigravity TUI Conversation Registration and Known ID Resumption Detailed Design

Status: Rejected based on real-device functional verification. Not implemented, committed, pushed, or deployed to existing installations.
Author: luna. Date: 2026-09-06 (JST).

## 1. Objective and Conclusion

Enables the Antigravity (`agy`) TUI to register its `conversation_id` in a location accessible to the agmsg bridge, allowing the bridge to resume a headless child process using that known ID.

The fundamental goal of monitoring is to deliver incoming agmsg messages directly into the conversational context of the TUI being operated by the human user.
The current standalone headless conversation mechanism was a fallback established when safe resolution of TUI conversation IDs was not yet achieved; it is not the ideal primary operating model.
However, to avoid disrupting existing state and active users in a single breaking update, standalone conversations remain supported strictly for explicit `standalone` configurations and legacy state continuations during transition periods.

On 2026-09-06 at 12:54 JST, real-device testing verified that an active TUI and a headless `agy` process could concurrently establish connections using the same conversation ID.
However, subsequent functional verification on 2026-09-06 at 14:03 JST revealed that while headless turns succeed against persistent storage, they are not reflected in the in-memory context of the active TUI.
Connecting with the same ID does not mean automated deliveries become visible in the running TUI.
Consequently, the registration and concurrent known-ID resumption model proposed herein is rejected and will not be implemented until a proven API exists to inject or reload external turns into an active TUI.

Codex monitoring is likewise not decoupled from its TUI.
`codex-monitor.sh` connects the TUI to a shared app-server via `--remote`, while the bridge resolves `thread/loaded/list` or stored thread IDs to initiate `turn/start` on the exact same TUI thread.
Because Antigravity lacks an app-server thread discovery API, this proposal attempted to replicate that responsibility via file-based registration.
Registration alone could not bridge this gap: Codex's shared app-server dispatches turns to the live thread, whereas an independent `agy` process specifying the same conversation ID does not update the live state of an active TUI.

Current `agy` releases provide no verified API equivalent to Codex's `thread/loaded/list` for enumerating running TUI conversations.
Therefore, rather than having the bridge discover conversations, the architecture required explicit registration by the TUI launcher.
Guessing conversation IDs via `--continue` or launching without IDs for unregistered TUIs is forbidden, restricting compatibility with fresh conversation creation to explicit transition modes.

This document targets the Antigravity driver within the canonical agmsg repository (local clone at `~/projects/agmsg`).
Measurements at the time of investigation:

- HEAD: `b57258f9da02f2f3730cb19d6d2f0ad06253cf0c`
- `origin/main`: `e127b06b63ade2f34b6f0698d1dc3375d6ed4c0c`
- Working tree: clean
- Host `agy --version`: `1.1.27`
- `agy --help` conversation options: `--continue` and `--conversation <ID>`. No option to list loaded conversations was found.
- `agy --input-format stream-json --output-format stream-json` maintains a single headless conversation across multiple stdin turns.
- A headless invocation targeting live TUI conversation ID `691ad6cf-2e20-4e01-a5a9-1c995ed5a9fb` returned `init` matching that ID.
- TUI PID `23563` remained alive throughout, and headless stderr showed no `active writer`, `already has`, or resume failures.
- No user input was sent to headless; the process group was terminated after verifying connection. TUI state, conversation history, and agmsg read states remained untouched.
- `lsof` showed only the TUI PID holding the presence lock. We did not confirm whether two processes can simultaneously hold the lock file descriptor. Confirmed behavior was strictly that headless initializes successfully with the same ID while the TUI is running without triggering Codex-style resume exclusivity errors.
- In disposable TUI conversation `b342aff2-614d-4f7f-a2f2-eb2775fc1caa`, the TUI initially memorized `kiwi`.
- While the TUI was idle, a bounded turn returning only `mango` was injected via headless using the same ID. Headless emitted init with the same ID, one `mango`, and SUCCESS; the TUI PID remained alive.
- Subsequently asking the live TUI "what fruit was just added from another connection?", the TUI answered `kiwi`. The external `mango` turn was not reflected in the live TUI context.
- Because it failed Section 6.1's initial criterion ("appears in the same conversation history, allowing the TUI to respond within that context after turn completion"), tests during active generation were skipped and verification concluded.

This design revision introduces no production code or configuration changes. Real-device tests were restricted to disposable TUIs under `/tmp/agy-concurrent-tui-project` and the bounded turns described above; existing TUIs, agmsg read states, and bridge states were not altered.

While the current standalone headless conversation mechanism does not achieve automated TUI delivery, it remains the officially supported workaround because it operates safely.
Implementation proposals for the registration architecture are preserved here for historical record, but specifications in subsequent sections are not approved requirements.

## 2. Terminology and Responsibilities

| Term | Meaning | Owner |
|---|---|---|
| TUI | Interactive `agy` session operated by a human user | TUI launch wrapper / SessionStart path |
| bridge | Resident process relaying unread agmsg messages to headless `agy` | `antigravity-bridge.mjs` |
| registration | JSON record binding a TUI to a bridge | TUI registration helper |
| lease | Tuple of owner, start time, and expiry proving registration validity | TUI launch wrapper |
| worker conversation | Headless conversation resumed by the bridge via `--conversation` | bridge |

TUI conversations and bridge headless conversations are treated as the same context only when sharing the identical ID.
Mismatched IDs are never silently unified, forked, or replaced with fresh conversations.

## 3. Registration Data Placement and Schema

### 3.1 Placement

Registration data is placed under `run/` in the same installation alongside existing agmsg state files.
Registrations are never written to databases, team configurations, or tracked project git files.

One JSON file is maintained per project, containing a `sessions` array to prevent multiple TUIs from overwriting one another.
The candidate path is defined below, to be aligned with existing `storage` / path helper naming conventions upon implementation:

```text
~/.agents/skills/agmsg/run/antigravity-tui.<project-hash>.json
```

The bridge accesses this JSON via dedicated Bash/Node helpers rather than reading it arbitrarily.
The helper provides read-modify-write locking under `flock`, temporary file creation within the same directory, `fsync`, atomic renames, owner-restricted permissions, and fail-closed handling of malformed JSON.
Concurrent registrations from multiple TUI wrappers acquire the lock, re-read the latest JSON, and update only their respective instance.
If acquiring locks, verifying re-read generations, or renaming fails, registration data remains unmodified.

### 3.2 Record Schema

```json
{
  "schemaVersion": 1,
  "project": "/absolute/project",
  "sessions": [
    {
      "instanceId": "stable-tui-instance-id",
      "team": "team-name",
      "role": "agy",
      "conversationId": "uuid",
      "ownerPid": 1234,
      "ownerStart": "process-start-token",
      "registeredAt": "2026-09-06T12:00:00+09:00",
      "lastSeenAt": "2026-09-06T12:00:00+09:00",
      "leaseExpiresAt": "2026-09-06T12:05:00+09:00",
      "state": "active"
    }
  ]
}
```

Required fields: `schemaVersion`, normalized `project`, `instanceId`, `team`, `role`, `conversationId`, `ownerPid`, `ownerStart`, `registeredAt`, `lastSeenAt`, and `state`.
`conversationId` must not be empty, guessed, or set to placeholder strings like `loaded`.
Timestamps use ISO 8601 with `+09:00` offsets, and human-facing logs use JST.

Because PID reuse cannot be detected from `ownerPid` alone, it is paired with `ownerStart`.
Lease expiration alone does not immediately delete registrations for other TUIs; the owner's process start token is re-verified first.
The bridge considers only records with `state=active`.
Records with `state=closed` are retained for historical visibility but excluded from candidate counts, latest selections, and resolution.

## 4. Registration Timing and Writers

### 4.1 TUI Startup

Rather than modifying standard `spawn antigravity` directly, registration logic resides in driver wrappers responsible for TUI launches:

1. The wrapper generates an `instanceId` or restores it from invocation arguments.
2. Spawns `agy` in TUI mode.
3. Once the TUI establishes its conversation ID, the registration helper is invoked from the process owning the TUI.
4. The helper atomically registers `conversationId`, process start token, team, role, and project.
5. Verifies registration before notifying or allowing reconnection from the bridge.
6. If registration fails, the bridge does not start; the TUI prints an error while remaining available for interactive use.

The writer must be the TUI wrapper or SessionStart path possessing direct knowledge of the conversation ID.
Bridges are strictly prohibited from guessing IDs or registering on behalf of a TUI.

This prohibition does not rely purely on caller conventions.
The TUI wrapper generates a cryptographically random capability before launch, passing it strictly over a dedicated file descriptor to the registration helper rather than in environment variables or argv.
In addition to the capability, the helper asserts that the target PID is a direct child of the wrapper, that PID and start tokens match, that the PID holds the presence lock for the `conversationId`, and that the working directory matches the normalized project path.
Any discrepancy aborts the write.
Headless bridges and their child processes close the capability file descriptor prior to spawn, and the registration helper rejects invocations lacking capabilities.
While not defending against arbitrary code executed by the same OS user, it mechanically closes off accidental writes from standard bridge paths.

Initial presence verification is restricted to Linux.
The target lock file is `${HOME}/.gemini/antigravity-cli/presence/<conversationId>.lock`, where `conversationId` must be a valid UUID.
The helper avoids parsing `lsof` text, enumerating symlinks in `/proc/<ownerPid>/fd/*` to confirm at least one file descriptor resolves canonically to the target lock.
In measurements on TUI PID `23563`, `/proc/23563/fd/46` pointed to `${HOME}/.gemini/antigravity-cli/presence/691ad6cf-2e20-4e01-a5a9-1c995ed5a9fb.lock` with mode `0600` owned by the user.
The wrapper extracts the conversation ID from this descriptor mapping rather than guessing from mtimes, directory listings, or `last_conversations.json`.

Platforms lacking `/proc`, non-default app data directories, unreadable descriptor symlinks, or PIDs holding multiple UUID presence locks will not generate TUI registrations.
In such scenarios, automatic registration fails closed, disabling `tui` mode.
Broadening platform support requires empirically validating equivalent binding mechanisms between PIDs and conversation IDs before updating plans.

If current `agy` binaries do not pass conversation IDs to hooks post-startup, the wrapper must confirm whether IDs can be extracted from stdout, known CLI responses, or official session metadata before implementation.
If no extraction path exists, the architecture reverts to explicit user commands (e.g. `bridge register`) rather than claiming automated registration support.

### 4.2 Heartbeat and Teardown

The TUI wrapper periodically updates `lastSeenAt` and refreshes leases.
Upon clean exit, it atomically marks records matching its `instanceId` and `ownerStart` as `state=closed`.
Detecting TUI termination prompts the bridge to shut down its headless child without terminating the process owning the TUI.

Close updates use the same `flock` and generation re-read sequence.
They never overwrite instances modified under different ownerStart tokens or records already marked closed.

Registrations remaining after abnormal crashes are classified as stale upon the next startup after verifying process start tokens and leases.
Stale records are removed only when ownership of the same instance can be verified, leaving foreign registrations intact.

## 5. Multiple TUI Sessions

### 5.1 Multiple Instances of the Same Role

When multiple TUIs share the same `project/team/role`, a single bridge must never monitor multiple conversations simultaneously.
Each TUI possesses a unique `instanceId`, and the role's bridge requires explicit selection:

- Bind to a specific TUI via `--instance <instanceId>`.
- Assign distinct roles per TUI (e.g. `agy-w1-pS`, `agy-w1-pT`).

Defaulting to "latest registration", "first registration", or "highest PID" is prohibited.
Multiple candidates without explicit instance flags trigger `NEEDS_ATTENTION`, inhibiting unread retrieval.

### 5.2 Exclusivity within the Same Role

Binds agmsg's existing actas/role exclusivity to conversation registration.
While a role is held by an active bridge, other TUIs cannot claim bridge registration for that role.
Formally supporting multiple concurrent TUIs requires splitting roles into distinct inboxes and bridge leases.

This prevents race conditions where multiple conversations compete to mark the same agmsg inbox read.
Implementing multiple TUI support via single-inbox fan-out is out of scope.

## 6. Bridge Startup and Resumption Logic

Prior to initializing `antigravity-bridge.mjs`, the bridge resolves exactly one valid registration for the target `project/team/role/instanceId`:

1. Uses `conversationId` only if a single registration matches leases, PID, start token, project, and role.
2. Launches `agy --input-format stream-json --output-format stream-json --conversation <ID>` when a valid ID exists.
3. Confirms that `init` returns an ID matching the registered ID.
4. Mismatches, multiple candidates, expired leases, corrupted data, or ownership conflicts halt without spawning fresh conversations.
5. Re-verifies that the stored `conversation_id` matches the registered ID after `init`.

Candidate selection strictly requires `state=active`, excluding closed, corrupted, expired, or PID-mismatched records.

### 6.1 Concurrent Turns Between TUI and Bridge

A successful `init` sharing the same ID is not sufficient to declare concurrent TUI and bridge turns safe.
Prior to implementation, the following must be measured using disposable TUI conversations:

1. While the TUI is idle, injecting a bounded message from headless causes it to appear exactly once in the shared conversation history.
2. The TUI remains capable of input and responses under the same ID after turn completion.
3. Injecting a headless turn while a TUI turn is active causes agy to either serialize or explicitly reject the injection without corrupting existing responses or history.
4. Upon rejection, the bridge holds the batch un-acked in an `uncertain` or replayable state.

Success requires no message loss, duplication, conversation ID mutation, TUI unresponsiveness, or history overwrites.
If behavior during active generation cannot be observed or if injections corrupt existing turns, concurrent TUI execution will not be implemented.
Without an external idle oracle, assuming safety based on timeouts or recent timestamps is prohibited.

Existing bridge headless state handling is preserved.
Registration serves as a separate mapping layer, leaving schemas for batches, acks, reservations, and violation latches untouched.

## 7. Compatibility and Migration from Existing Bridges

### 7.1 Compatibility

Conversation policies are recorded per role in dedicated configuration files:
`run/antigravity-conversation-policy.<project-hash>.<team>.<role>.json`, containing `schemaVersion`, normalized project, team, role, and `mode`.
`mode` accepts strictly three values and is never inferred from bridge state fields:

| mode | Purpose | Conversation ID Source | Fresh Conversation Creation |
|---|---|---|---|
| `tui` | Default for new setups; routes to user TUI | Active registration only | Prohibited |
| `standalone` | Explicit user-configured isolated worker | Bridge state, falling back to agy init | Permitted |
| `legacy-state` | Preserves existing pre-update isolated workers | Verified pre-existing bridge state only | Prohibited |

Missing policies are treated as `unconfigured`, refusing startup.
Because `delivery.sh set monitor antigravity <project>` does not take team/role arguments, it neither creates nor alters conversation policies; it configures project-level delivery envelopes only.
Defaulting new setups to `tui` does not mean the bridge infers missing policies. It defines an evaluation order: once team/role are confirmed, the TUI wrapper verifies policy absence, creates a `tui` policy following registration ownership validation, and only then allows bridge startup.
Existing policies are never overwritten by the TUI wrapper. If the mode is `tui`, it is re-verified and reused; if `standalone` or `legacy-state`, it halts, requiring explicit policy changes.
`standalone` policies are created only via explicit user invocation: `antigravity-conversation-policy.sh set standalone --project <project> --team <team> --name <role>`.
Altering existing modes is confined to this CLI; creating-on-absence during bridge startup, inferring from state, or batch-generating policies across all roles is forbidden.
Migration scripts enumerate valid existing bridge states, creating `legacy-state` policies only after validating ownership of project/team/role and state files. This one-time compatibility measure ensures existing isolated workers are not broken by updates prior to manual migration, without switching them to `tui`.
Roles lacking state, containing corrupted records, unresolved batches, or ambiguous entries are halted without writing migration policies.
Writers (TUI wrapper, policy CLI, migration script) acquire per-policy `flock`s, re-read contents, verify ownership and modes, and save via `fsync` and atomic rename. Failures preserve existing policies.
Status commands display delivery mode and conversation policy independently.

New configurations default to `tui`, failing closed with registration instructions if active registrations are absent.
Concurrent TUI operation is the canonical monitor architecture.

Bridge states possessing `conversation_id` in existing installations are not invalidated by updates alone, provided migration successfully creates a `legacy-state` policy.
Until registrations exist, explicit policies and verified states allow isolated conversations to persist as transitional fallbacks. States failing policy creation are not continued implicitly.
Once new TUI registrations are created, mismatches between state IDs and registrations trigger `NEEDS_ATTENTION` rather than automatic switching.

Users wishing to run isolated workers explicitly select `standalone` mode.
`standalone` permits fresh conversation creation but clarifies that messages do not route to the TUI.
Implicit fallbacks, automatic conversion to standalone upon registration failures, and guessing via `--continue` are prohibited.

### 7.2 Migration Procedure

1. Display current bridge state `conversation_id`, project/team/role, and timestamps via `status`.
2. Human user confirms that the target TUI matches the known ID.
3. Register the matched ID and instance explicitly via registration helpers.
4. Stopping or restarting bridges respects existing batch phases rather than auto-replaying.
5. Verify parity between registration and bridge state via `status` and bounded self-tests.

Migration never deletes or overwrites existing bridge state.
Unresolved batches halt migration, requiring standard status/resolve procedures first.

## 8. Post-Registration of Pre-Existing Running TUIs

### 8.1 Automated Post-Registration

Because public `agy` features lack APIs to enumerate active TUI conversation IDs externally, automated post-registration of pre-existing TUIs is not guaranteed in this release.

### 8.2 Explicit Post-Registration

Manual post-registration of existing TUIs cannot satisfy wrapper capability and direct child PID checks, excluding it from initial implementation.
Displaying or copying conversation IDs does not prove writer authorization.
Helpers such as the following may be reconsidered only if the TUI gains capabilities to emit signed session metadata or capabilities:

```text
bash scripts/drivers/types/antigravity/conversation-register.sh \
  --project <absolute-project> --team <team> --name <role> \
  --instance <instance-id> --conversation <known-id>
```

Validation requirements:

- Valid UUID format.
- Project/team/role matches registered identity.
- No collision with existing IDs for the instance.
- PID/start token, presence lock, and wrapper capability confirm the same TUI instance.
- Rejection if another active registration exists for the role.

Existing TUIs unable to export IDs externally will report post-registration as unsupported, advising users to launch fresh TUIs via registered wrappers.
Treating recent entries in history logs or `last_conversations.json` as active TUIs is rejected.

## 9. Failure Invariants and Safe Fallbacks

| Condition | Behavior |
|---|---|
| Missing registration | `tui` mode halts without creating fresh conversations; prints launch instructions. |
| Multiple registrations | Demands explicit instance flag; halts unread retrieval. |
| Only closed registrations | Halts due to lack of active candidates; avoids resuming closed IDs. |
| Expired lease | Re-verifies owner PID/start token; halts if unverifiable. |
| PID reuse | Rejects due to start token mismatch. |
| `init` ID mismatch | Moves bridge to `NEEDS_ATTENTION`; inhibits acks and retries. |
| Bridge state / registration mismatch | Avoids auto-switching; demands status/resolve resolution. |
| Abnormal TUI exit | Preserves unresolved batches without transferring registrations to other instances. |
| Corrupted JSON / atomic write failure | Fails closed; halts cursor advancement. |

The design prioritizes preventing conversation context mix-ups and duplicate inbox reads over availability.
Spawning fresh conversations while unregistered is prohibited.

## 10. Implementation Targets and Test Plan

Candidate files upon implementation (none are modified at this stage):

- `scripts/drivers/types/antigravity/antigravity-bridge.mjs`
- `scripts/drivers/types/antigravity/antigravity-monitor.sh`
- `scripts/drivers/types/antigravity/conversation-register.sh` (new candidate)
- `scripts/drivers/types/antigravity/_delivery.sh`
- `scripts/drivers/types/antigravity/template.md`
- `tests/antigravity_bridge.test.mjs`
- `tests/fixtures/fake-antigravity.mjs`

Test addition order:

1. Registration JSON atomic updates with flock, concurrent writers, schema validation, and fail-closed handling of malformed JSON.
2. Converting a single active registration into `--conversation`.
3. Startup without registration halts without creating fresh conversations.
4. Rejecting `init` ID mismatches, PID reuse, and expired leases.
5. Halting on ambiguous multiple instances of the same role.
6. Coexistence of role-partitioned TUIs as distinct bridges/inboxes.
7. Resuming legacy state IDs and detecting discrepancies against new registrations.
8. Verifying zero regressions in existing headless peek, batch, ack, and uncertain recovery logic.
9. Fake agy accepting `--conversation <ID>` and verifying matching init IDs across multiple turns.
10. Real agy smoke testing using dedicated roles and bounded messages, executed only upon explicit approval.
11. Rejecting registrations lacking capability FDs, originating from bridge PIDs, mismatched presence locks, or indirect child PIDs.
12. Excluding `state=closed` from candidates; concurrent close/register preserves other instances.
13. Empirical validation of idle and busy injection in dedicated TUIs against Section 6.1 criteria.
14. Independent testing of new `tui`, legacy state migration, and explicit `standalone` paths without conflation.
15. Rejecting missing policies and unknown modes; verifying independent status display of delivery modes and conversation policies.
16. Registering strictly single presence locks from Linux `/proc/<pid>/fd`, rejecting zero, multiple, foreign PID, non-UUID, or non-default directory locks.

The mechanism by which TUI wrappers acquire conversation IDs will be verified on real `agy 1.1.27` hardware rather than fixtures alone.
If unavailable, the plan will be revised to restrict scope strictly to explicit registration.

## 11. Review Perspectives

- Writer authority is strictly confined to the TUI side, preventing the bridge from guessing conversations.
- Fail-closed behavior when the two sources of truth (state.json and registration) disagree.
- Preventing mis-selection among multiple TUIs sharing roles/inboxes based purely on timestamps or PIDs.
- Robustness of ownership evaluation across PID reuse, lease expiration, and abnormal TUI crashes.
- Seamless migration without breaking batch/ack/uncertain contracts in existing bridges.
- Avoiding over-claiming post-registration capabilities for pre-existing TUIs.
- Preventing conflation of `--continue`, history caches, or desktop imports with live TUI discovery APIs.
- Ensuring necessary fake and hardware test coverage is planned prior to implementation, commit, and push.

## 12. Out of Scope

- Implementing new APIs in agy CLI or desktop binaries.
- Injecting arbitrary inputs into external processes or driving TUI interfaces.
- Inbox fan-out across multiple conversations.
- Forcible takeover of existing TUIs using registrations.
- Direct editing of DB, team configs, or existing bridge state files.
- Implementing, committing, pushing, or deploying code during this planning phase.
