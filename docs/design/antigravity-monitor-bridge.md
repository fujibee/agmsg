# Antigravity Monitor Bridge Implementation Plan

Status: Proposed, pending review. Implementation, commit, push, and deployment to existing installs are unapproved and pending.
Author: luna. Date: 2026-09-05 (JST).

## 1. Scope and Investigation Baseline

Relays unread agmsg messages to a dedicated headless `agy` resident child process.
Incoming messages are processed as the next turn in the conversation, preserving the context of the same `conversation_id`.
Injecting into already-running interactive TUIs, re-implementing TUI screen/interactive approval flows, and modifying the Gemini driver are out of scope.

The canonical clone is `~/projects/agmsg`.
At the start of investigation, the branch was `main`, HEAD was `e0f10a87ed07561812a5cff89b85fcf934573e7c`, and the working tree was clean.
`origin` is `fujibee/agmsg`, and the fork remote is `joelmitz`.
Because this differed from the baseline `e1eb933` in the request prompt, this document uses the local HEAD source as its baseline, re-verifying diffs prior to implementation.
No fetch, checkout, or merge operations are performed during the creation of this plan.

Document placement matches `docs/design/`, aligned with [docs/design/remote-sync.md](remote-sync.md).
`ref/` is not used as it is not intended for active implementation plans.

Evidence classifications:

- Confirmed via local code: Antigravity specifies `monitor=no`, `delivery_modes=turn off`, and uses rule-file based delivery plugs.
- Confirmed via real CLI version/help by luna: `agy 1.1.26` provides bidirectional stream-json and `--conversation`.
- Received via request description as real-device verification by agy maintainer: The process survives after one turn and maintains context across subsequent turns via stdin.
- Confirmed via official documentation: User input, init/step_update/result outputs, waiting for result, EOF termination, and lack of support for control_request/control_response.
  Reference: [Headless mode](https://antigravity.google/docs/cli/headless).
- Unverified in this document: Full combinations of errors, restarts, approval refusals, Windows platform support, and combining stream-json with explicit conversation resumption.

## 2. Initial Implementation Scope

The initial operating model is a single-role headless worker explicitly started from a terminal.
Human users send messages from a separate agmsg session and observe results in the bridge terminal.
No arbitrary-input interactive UI or system daemon services are added.
Uses Node.js and Bash, avoiding standalone WebSocket server daemons.

Proposed invocation interface:

```text
bash scripts/drivers/types/antigravity/antigravity-monitor.sh \
  --project <absolute-project> --team <team> --name <registered-role>
```

`delivery.sh set monitor antigravity <project>` merely records settings and displays launch instructions; it does not automatically spawn billable conversations upon mode changes alone.
Startup strictly requires a registered role and aborts if already held by another live session.
To avoid competing with existing agy TUIs for the same role, initial testing uses a dedicated headless role.
While delivery mode is tracked per project/type, running processes are managed per project/team/role.

## 3. Differences from the Existing Codex Mechanism

| Responsibility | Existing Implementation | Handling in Antigravity |
|---|---|---|
| Unread detection | `codex/watch-once.sh`, storage facade | Reuses common storage/subscription APIs. The initial version encapsulates detection and retrieval in a dedicated Bash helper, preserving existing Codex behavior. |
| Role exclusivity | `scripts/lib/actas-lock.sh`, `subscription.sh` | Reuses identical ownership verification, name encoding, and owner-restricted release mechanisms. |
| Conversation tracking | `scripts/lib/role-session.sh` | Used as an advisory resumption target. In-flight delivery tracking is maintained separately. |
| Runtime environment | app-server and TUI share the same WebSocket endpoint | The bridge directly owns the stdin/stdout of the child `agy` process. |
| New turn input | `turn/start` in `codex-bridge.js` | Emits a single NDJSON user event line. |
| Busy/idle state | turn/thread notifications, watchdog | Defined as busy from input injection until result reception. |
| Process supervision | `codex-bridge-launcher.sh` | Small dedicated launcher paired with internal bridge restart logic. Avoids replicating the entire Codex launcher. |
| Message body fetch | Inline mode calls `inbox.sh` prior to turn/start | Decouples unread retrieval from read acknowledgement. Preserves standard inbox semantics. |
| Monitor capability | Codex manifest specifies `readiness_sentinel=no` (renamed from `monitor=no` in #1214) | Maintains `readiness_sentinel=no` due to absence of a native Monitor. |

Reference code: `scripts/drivers/types/codex/{codex-monitor.sh,codex-bridge.js,codex-bridge-launcher.sh,watch-once.sh,eligible-pairs.sh}`.
Codex RPC, thread discovery, TUI attach, and process/spawn primitives are not reused.
We adopt Codex's unread set comparison, exclusivity locking, retry bounds, and diagnostic patterns.

## 4. Process and Turn Lifecycle

```text
Sender → Existing agmsg store (remote sync via existing engine)
                       ↓ Unread snapshot
                Antigravity bridge
                       ↓ stdin: user NDJSON
                agy headless child process
                       ↓ init / step_update / result
            State update, display, and ack of received IDs
```

Bridge stdout presents human-facing startup and response outputs, while stderr carries diagnostics.
Child stdout is parsed strictly as machine-readable stream-json; child stderr is continuously drained to prevent buffer stalls.

| State | Behavior / Transition |
|---|---|
| STARTING | Verifies settings, binaries, role ownership, and local state. Spawns `agy --input-format stream-json --output-format stream-json` directly without an intermediate shell. |
| INITIALIZING | Sends initial fixed context as a user event. Communicates only type/project/team/role and reply instructions; unread bodies are deferred. |
| IDLE | The initial or delivery turn completed, and read acknowledgement finished. Polls unread messages every 2 seconds by default. |
| BUSY | A batch has been injected. New inputs are held; incoming messages remain in storage. |
| ACK_PENDING | Association between a SUCCESS result and the batch is persisted. Acknowledges only the received message IDs, returning to IDLE on success. |
| STOPPING | Closes stdin without taking new messages. Awaits current turn completion and terminates only owned processes. |
| NEEDS_ATTENTION | Unclear result, protocol error, role mutation, or unrecoverable state. Logs reason and suspends automatic delivery. |

To prevent circular initialization stalls where `init` is withheld until the first user input, initial context injection is permitted prior to `init`.
The initial turn carries no agmsg IDs and performs no read acknowledgements.
The bridge reports ready only after the conversation initializes, its ID is stored, and the initial turn completes successfully.

NDJSON handling rules:

- Inputs are formatted via a JSON serializer, ensuring multi-line bodies form a single NDJSON line. `-p` and `--prompt-interactive` are prohibited.
- Buffers partial and multi-line chunks, parsing line by line. Proposed initial line limit is 8 MiB; exceeding this stops delivery with diagnostics.
- Persists the `conversation_id` from `init`, asserting match on subsequent ID-bearing events. Silent switching to foreign conversations is forbidden.
- `step_update.text_delta` provides incremental streaming display; `result.response` represents final output, avoiding duplicated logs.
- Exactly one `result` is expected per input. Only `SUCCESS` denotes success; ERROR, CANCELED, INTERRUPTED, and WAITING are never treated as success.
- Unknown event types are logged to diagnostics and ignored. Malformed JSON, duplicated results, or unsolicited results trigger an immediate halt.
- Monitors stdin backpressure to verify full write completion. Successful writes do not imply model task completion.
- Initialization timeout is 60 seconds; normal turn timeouts align CLI print-timeout with bridge limits (proposed: 5 minutes plus 30 seconds buffer). Timeouts halt as incomplete, preventing piggybacking subsequent turns into the same conversation.

## 5. Unread Message Fetching, Read Acknowledgement, and Crash Handling

Proposes a new Bash helper: `antigravity/inbox-transport.sh`.
Because existing `scripts/inbox.sh` bundles display and marking read, it cannot be used for pre-delivery retrieval.
The helper uses `agmsg_storage_load` and the storage facade's `storage_list_unread` / `storage_mark_read_batch`, avoiding ad-hoc DB/team queries.

Helper contract:

- `peek`: Checks project/type/team/role and ownership, returning unread `{id, from, to, body, at}` without marking read. Distinguishes retrieval errors from zero unread messages via exit codes.
- `ack`: Accepts a JSON array of batch IDs via stdin, re-verifies ownership and recipient, and acknowledges strictly those IDs. Newly arrived messages are excluded.
- Column names conform to existing storage facade responses; this defines the helper's external interface without modifying storage schemas.
- Proposed batch limits: up to 20 messages or 64 KiB total body size. Messages exceeding limits individually are not truncated; the bridge logs their IDs and halts.

The bridge maintains at most one in-flight batch record under the installation's `run/` directory via atomic replace.
We propose `antigravity-bridge.<project-key>.<team-key>.<role-key>.state.json` using existing actas name encoding.
Permissions are restricted to the owner; bodies are omitted from regular logs.
State fields include schemaVersion, owner, project, team, role, conversation_id, batch ID, message IDs, bodies, and phase.
Phase progresses through prepared / sent / completed / uncertain, persisting prepared prior to input injection.
Because role-session is purely advisory, it does not replace this state file.

Normal sequencing: `peek → save batch → inject user event → receive SUCCESS → save completed → ack → clear batch`.
Marking read denotes completion of the model's turn, not business task completion or sent replies.
Replies must be explicitly executed by the agent via `send.sh`.
Headless receipt tracking is handled exclusively by the bridge.
In addition to the initial context, `antigravity/template.md` adds a branch dedicated to monitor workers.
Under this branch, argumentless `$agmsg` avoids marking read and prints bridge status instead.
It explicitly warns against using `inbox.sh` / `check-inbox.sh` for message consumption, directing replies through `send.sh`.
Standard turn/off session defaults remain untouched.

### 5.1. Mechanical Guard Against Secondary Readers

Documentation warnings alone cannot stop a worker from executing existing skills that invoke inbox scripts.
Therefore, the team/role owned by a monitor worker reserves a "bridge managing read" latch, validated at all shared read entry points.
The reservation binds to the actas owner and is not cleared by PID death alone while unresolved batches persist.

- Introduces `scripts/lib/bridge-read-guard.sh`, hooked after storage facade loading to protect both `storage_mark_read_batch` and `storage_read_cursor_consume`.
  Implementation tests verify that `inbox.sh` and `check-inbox.sh` traverse this guard.
- Standard attempts to mark messages read for a reserved team/role are rejected prior to altering storage.
  Validation inspects the reservation and owner rather than relying on worker environment variables, rejecting calls even if environment variables are stripped.
- The sole exception is `inbox-transport.sh ack` for completed batches matching the verified owner.
  Authorization is bound to the parent bridge's reservation, batch ID, and stored ID set, resisting bypass via environment variables like `ALLOW_ACK=1`.
  Passing authorization from parent to ack helper is reviewed prior to implementation and is never inherited by worker child processes.
- Rejected attempts are recorded in a violation log tied to the reservation (omitting bodies).
  To catch violations even if existing callers treat facade failures as non-fatal, the bridge checks the violation log before injection, during BUSY, and prior to result processing.
  Detecting violations forces `NEEDS_ATTENTION`, inhibiting completed state writes, acks, and subsequent turns even if `SUCCESS` arrives.
- If the parent successfully reads a logged violation, or if tool steps in stream-json invoke commands equivalent to `inbox.sh` / `check-inbox.sh`, the parent transitions to `NEEDS_ATTENTION`. If logging fails and no matching tool appears in the stream, the guard's read rejection and state preservation act as hard guarantees, though parent violation detection is not guaranteed (arbitrary code execution outside stream-json is out of scope).
- Manual human inbox commands are also rejected while reservations are active.
  Reading messages requires `peek` to avoid clearing reservations and advancing cursors unannounced.
  Reservations clear only after worker termination, batch resolution, and role ownership checks.

This boundary guards against accidental secondary consumption by standard scripts within the same installation.
It is not a security boundary against malicious arbitrary code, direct DB manipulation, or external installs.
Operating policy requires that dedicated roles are not shared across automated receivers.
Even if external consumption occurs, stored batches are preserved for recovery as detailed below.

### 5.2. State-Based Batch Recovery Independent of Unread State

| Recorded State on Abnormal Exit | Handling upon Restart |
|---|---|
| No batch, recorded conversation present | Attempts resumption using the same conversation ID. Real-device verification of explicit resumption is a release prerequisite. |
| prepared / sent / uncertain | Transmission status and tool side-effects are indeterminate. Preserves unread state, enters `NEEDS_ATTENTION`, and prohibits automatic re-injection. |
| completed | Retries ack strictly for the same ID set. Does not re-run the model. |
| Corrupted / unwritable state file | Halts without advancing cursors. Avoids silently creating fresh conversations. |

This design does not guarantee exactly-once side-effect execution.
Crashing after model success but before saving `completed` results in an indeterminate state.
Indeterminate states must be resolved explicitly by inspecting logs and conversations.
The source of truth for recovery is the stored message IDs and bodies in the state file, never reconstructed from current unread queries.
Even if external storage marks messages read, prepared/sent/uncertain states are not considered complete, and state files are preserved.
Explicit replay reinjects stored bodies with the original batch and message IDs, performed only after assessing potential duplicate side-effects.
Explicit ack targets strictly stored IDs, resolving idempotently even if IDs are already marked read.
Section 5.1's mechanical guard prevents secondary readers from discarding subsequent messages that were never saved in the state.
Implementation includes a `status` command and explicit recovery commands to choose between acknowledgement and replay, confirming target IDs.
Automated role transfer is prohibited while unresolved batches persist.

## 6. Restart, Teardown, and Role Ownership

If the child process crashes while IDLE, the bridge restarts the same conversation up to 3 times (at 1s, 5s, and 15s intervals).
Failed resumptions never fall back to silent conversation creation.
The restart budget resets upon one successful turn completion, preventing infinite restart loops on persistent launch failures.
Bridge crashes in the initial version do not auto-daemonize; the exit is visible in the terminal, recovering state upon the next explicit launch.

Startup acquires existing actas ownership, re-verifying it prior to peek, stdin injection, and ack.
Losing ownership suspends subsequent input, recording indeterminate state if currently BUSY.
Processes never kill foreign PIDs; teardown matches the child PID against recorded process start tokens.

On SIGINT/SIGTERM or switching from monitor to turn/off, the bridge stops new peeks, closes stdin, and waits up to 30 seconds for graceful exit.
Remaining child processes are terminated only after verifying identity, preserving incomplete batches.
Normal shutdown cleans up its own readiness/PID files and locks without deleting conversation records or indeterminate batches.
If mode-switch teardown fails, the failure is reported, inhibiting automatic turn retrieval.

## 7. Integration with delivery.sh and type.conf

Adds `delivery_modes=monitor turn off`.
`both` is omitted from the initial release.
`readiness_sentinel=no` (renamed from `monitor=no` in #1214) is maintained, reflecting the lack of a native Monitor and preserving spawn ready checks.

| Operation | Designed Behavior |
|---|---|
| set monitor | Saves headless configuration. Disables existing turn rules and displays launch instructions. Does not spawn CLI processes. |
| status | Displays configured mode and runtime status independently, distinguishing stopped, ready, busy, and needs-attention states. |
| set turn | Stops the bridge for target project/type, then delegates to standard `rulefile_apply turn`. |
| set off | Stops target bridge and disables automatic retrieval, preserving unresolved batches and conversation records. |
| monitor launch | Verifies mode, registration, role ownership, binaries, and state storage paths before spawning. |

Specializes `antigravity/_delivery.sh` for apply, status, on_enable, on_disable, runtime_status, and teardown guidance.
Because existing `rulefile_status` checks turn/off purely by file presence, it cannot be reused as-is.
New mode configuration is stored as an explicit marker within the existing `hooks_file` region without overwriting other rules.
The marker format will be finalized during implementation review to minimize diff footprint while preserving rulefile structure.
Mode detection treats the marker as the canonical source of truth, avoiding treating PID presence as configuration state.
If `set turn` lacks dedicated teardown callbacks, a minimal hook is added prior to `apply_settings` in the common dispatcher, defaulting to no-op for other types.
Turn rulefiles are withheld until bridge shutdown and batch resolution succeed, preventing secondary auto-retrieval.

Standard `spawn antigravity` retains its interactive TUI behavior.
Initial monitor execution is confined to dedicated commands, avoiding mingling stream-json with existing `--prompt-interactive` paths.
Future spawn integration will connect via manifest spawn plugs or driver callbacks.
Because the headless launch command waits for readiness and reports success directly, masquerading behind native Monitor sentinel contracts is unnecessary.

## 8. Approvals and User Presentation

Does not transmit `control_request` or `control_response`.
Because unapprovable tools may soft-deny while the process exits cleanly, `SUCCESS` is not equated with business task success.
Initial validation uses bounded read and templated reply tasks.
Tool permissions such as `send.sh` follow existing user approval policies with bounded scopes, avoiding global bypass flags.
Requests requiring interactive confirmation yield control back to dedicated interactive sessions.

Human-facing logs present JST timestamps, role, conversation_id, batch ID, state, and exit reasons.
Message bodies and tool outputs are limited to necessary terminal display; credentials are never written to diagnostic files.
Headless response display is decoupled from agmsg replies; the bridge never automatically replies to senders.

## 9. Target Files and Implementation Order

Proposed path layout (this document is the only file created at this stage):

| Phase | Scope | Completion Criteria |
|---|---|---|
| A | Test fixtures for fake agy and isolated stores under `tests/`; Antigravity contract tests | Recreates init delays, multiple turns, abnormal exits, and corrupted JSON on demand. |
| B | `antigravity/antigravity-bridge.js`, `inbox-transport.sh` | Supports single role, unread peek, turn-by-turn injection, result handling, and ID-level acks. |
| C | `antigravity/antigravity-monitor.sh`, state/status/teardown helpers | Supports explicit launch, exclusivity, termination, resumption, and indeterminate halts. |
| D | `antigravity/type.conf`, `_delivery.sh`, and `scripts/delivery.sh` as needed | Supports monitor/turn/off configuration, status reporting, teardown, and passes regression tests on other types. |
| E | `antigravity/template.md`, `docs/agent-types.md`, operational guide | Explains differences from TUI, startup, replies, approvals, and recovery procedures. |

Base path for Antigravity-specific relative paths is `scripts/drivers/types/antigravity/`.
Storage facade changes are strictly limited to wiring Section 5.1's read guard for reserved teams/roles.
Standard unreserved operations proceed untouched; Codex bridge and Gemini configurations remain unaltered.
Phase B includes `scripts/lib/bridge-read-guard.sh` and facade hook integration points.
If extracting existing components becomes necessary, rationale and impact will be submitted for pre-implementation review.

## 10. Verification and Release Criteria

Tests run against separate installations, isolated teams, and fake agy processes, avoiding active `airsurf` or normal CLI credentials.
Testing in separate installations follows established isolation procedures rather than relying on environment variable overrides alone.

1. Starts IDLE before arrival; first turn initiates upon arrival; second message enters the same conversation after result.
2. Correctly handles split buffers, multi-line chunks, bodies containing newlines, unknown events, and large stderr bursts.
3. Terminating before/after result, before/after completed state save, and before/after ack causes no unread message loss or duplicate auto-injections.
4. Ack failures do not re-execute the model; only target IDs are re-processed. Subsequent IDs remain unread.
5. Verifies rejection of duplicate launches, conflicting roles, foreign projects, ownership transfers, PID reuse, and restarts with unresolved batches.
6. Switching from monitor to turn/off halts only the target bridge, preserving monitors for other types and projects.
7. Unmet readiness, exiting while busy, rejected approvals, and unrecoverable resumptions are never reported as "successful delivery".
8. Passes existing delivery, spawn, and role-session test suites for Codex, Claude, and Gemini.
9. Real agy smoke testing verifies context preservation across two messages, idle resumption, and explicit reply history using a dedicated role. Executed only upon separate approval.
10. Adds test cases where fake agy invokes real isolated `inbox.sh` / `check-inbox.sh` during BUSY, or attempts argumentless `$agmsg` consumption.
    Verifies that after injecting batch A and creating subsequent message B, both IDs remain unread, a violation is recorded, and the bridge enters `NEEDS_ATTENTION`.
    Does not rely on worker exit codes alone; asserts that no ack occurs even if followed by SUCCESS or a crash.
    Includes positive controls where unreserved stores mark messages read, demonstrating tests are not false negatives.
11. Creates uncertain states in isolated fixtures where storage is pre-marked read, verifying that explicit replay or explicit ack can be chosen from state IDs/bodies.
    Neither auto-replays nor infers resolution from "zero unread messages".
12. Linux is the initial supported target; Windows and macOS are not documented as supported until path, process, and Bash variations are verified.

## 11. Risks, Deferred Items, and Review Perspectives

This represents a medium-scale addition even in its initial form.
While the process adapter itself is compact, boundaries governing read acknowledgement and abnormal exits dictate overall reliability.
We deliberately avoid introducing new persistent queues or generalized bridge frameworks, constraining state strictly to single batches.

Items to resolve prior to implementation:

- Confirming that `--conversation` and stream-json maintain the identical conversation across resumptions. If unverified, automated restarts will be disabled in favor of explicit stops.
- Ensuring required tools function within the initial context, and operational impacts of approval rejections are documented.
- Verifying single-batch state persistence, ID-level acks, and mechanical rejection of secondary readers across both storage drivers.
- Finalizing the parent-only authorization handover for acks, handling log failures, and reservation release ordering during pre-implementation review.
- Assessing proposed mode markers, recovery command arguments, and threshold bounds (treated as proposals, not permanent specifications).

Grok will be requested to provide a PASS/BLOCKER review focusing on state transitions, retransmission heuristics, mode release, role exclusivity, and impact on existing agent types.
Plan approval does not constitute authorization for implementation, commit, push, or deployment to existing installations.

## 12. Plan Review History

On 2026-09-05 18:50 JST, grok evaluated the initial revision as BLOCKER.
Initial SHA-256: `7727c4a8573219f89f0a1fc33f11da1b3464304e3877946a9b96af816965ab43`.
The sole objection was: "The plan fails to close the secondary reader where the worker advances read state prematurely via existing inbox commands."
Additions made: Section 5.1 template branch and shared mechanical read guard, Section 5.2 state-as-source-of-truth recovery, and verification criteria 10 and 11.
Withdrew initial assumptions that "initial context alone prevents secondary reads" and "manual inbox commands are permitted during active reservations", restricting active read acknowledgements strictly to bridge acks.
Re-review pending.
Maintains the record of initial luna measurements on `agy 1.1.26`, noting subsequent receipt of grok's update report to `1.1.27`.
