# Antigravity TUI PTY Monitor Design

Status: Implemented and tested on an isolated test machine. The lightweight screen model, terminal window-size synchronization, and receipt composition rules are pending re-review; not yet pushed.
Author: luna. Date: 2026-09-06 (JST).

## 1. Conclusion and Rationale

agmsg's automatic message delivery for Antigravity exclusively owns the PTY of an `agy` process launched via a dedicated wrapper, injecting unread messages into the same TUI at safe idle boundaries.

The existing headless bridge passes unread messages to a separate `agy --input-format stream-json` process. While messages reach the worker conversation, they do not update the live context of the TUI viewed by the human user. In an experiment sharing the same conversation ID on 2026-09-06 14:03 JST, the headless `mango` invocation succeeded, but the TUI remembered only the prior turn's `kiwi`. Consequently, conversation ID registration and headless resumption are not viable mechanisms for TUI delivery.

Between 14:45 JST and 14:48 JST on 2026-09-06, we tested launching an `agy 1.1.27` TUI via PTY within a disposable project at `/tmp/agmsg-agy-pty-probe.13nFeO`. The TUI conversation ID was `33044ac8-6b1d-4f7d-aea4-06b810cbe8c1`. The initial turn in Japanese returned `READY`, a turn simulating incoming external delivery returned `RECEIVED`, and a subsequent turn returned the updated memory word `kohaku`. PTY input is directly reflected in the same live TUI conversation.

Conversely, injecting external input while `DRAFT:` remained in the TUI input line resulted in `DRAFT:INCOMING` concatenated on the screen. Because this corrupts human draft input in addition to the transmitted message, external input must never be injected without observing the input prompt state.

This verification was limited to sequential input sent over the same PTY to a TUI spawned on that PTY. Raw transcripts, TUI PIDs, and multiplexing with human input during relay were not preserved or measured. This serves as the rationale for selecting the architecture, not proof of implementation correctness. Section 10 re-verifies these properties on an isolated test machine while capturing raw transcripts, child PID/start tokens, conversation IDs, and terminal attach status.

In the public CLI of `agy 1.1.27`, we found no API for discovering an active TUI conversation and initiating a turn within it. Neither `--conversation` nor Remote Control serve as APIs for this purpose. Therefore, existing TUI sessions started without the wrapper are excluded from the initial monitor scope.

## 2. Scope

The target is a single newly spawned TUI on Linux associated with a single `project/team/role` tuple. The launch command is:

```text
bash scripts/drivers/types/antigravity/antigravity-tui-monitor.sh \
  --project <absolute-project> --team <team> --name <registered-role>
```

This command creates a PTY, starts `agy` on its slave side, and mediates both the user's terminal and the agmsg bridge on the master side. Normal `agy`, existing `spawn antigravity`, and the headless `antigravity-monitor.sh` remain unchanged. TUI monitor mode requires explicit startup; `delivery.sh set monitor` merely configures the mode and prints startup instructions.

Out of scope: hijacking existing TUIs, cross-terminal screen scanning, `send-keys` to existing tmux panes, Desktop/Remote Control automation, fan-out from one inbox to multiple TUIs, Windows/macOS support, and automated responses to unverified permission prompts.

## 3. Architecture

```text
User terminal stdin ────┐
                        ├─ TUI PTY supervisor ─ PTY master/slave ─ agy TUI
agmsg unread snapshot ──┘         │
                                  ├─ durable state / reservation
                                  └─ inbox-transport peek / ack
```

The PTY backend uses Python 3's standard library modules `pty` and `termios`. agmsg already includes pre-flight checks for Python 3, requiring no additional packages or native build steps. Piping stdout directly was rejected because it strips TUI escape sequences, window-size notifications, and bracketed paste mode. The supervisor holds the child's stdin/stdout directly and relays raw input from the parent terminal. Prior to startup, the parent terminal's `TIOCGWINSZ` is applied to the child PTY via `TIOCSWINSZ`, with identical synchronization and child notification performed on each parent `SIGWINCH`. Because nested PTYs do not automatically inherit terminal dimensions, this synchronization is a prerequisite for startup.

`antigravity-tui-monitor.sh` validates arguments and Linux/TTY prerequisites before `exec`ing the supervisor. The supervisor acquires `actas_lock_claim` and an existing bridge reservation, preventing concurrent reads of the same role by headless bridges, turn rules, or other supervisors. The reservation holds all fields required for ack authorization: `owner`, `pid`, `start`, `state`, `actas`, `violations`, and `capHash`. The ack transport runs as a direct child of the supervisor, passing the capability strictly over file descriptor 3. This satisfies existing assertions: `parent.ppid === reservation.pid`, matching PID/start token, valid capHash, and exact batch ID set match. Capabilities are never inherited by the agy child or the human-input relay.

## 4. State Machine and Read Processing

Reuses existing `inbox-transport.sh` and `bridge-read-guard.mjs`. The order of unread fetching and marking read remains unchanged:

```text
IDLE
  → peek
  → persist prepared state
  → wait for injection readiness
  → paste into PTY + Enter
  → persist sent state
  → verify TUI turn completion
  → persist completed state
  → ack (saved IDs only)
  → IDLE
```

The state file is stored at `$SKILL_DIR/run/antigravity-tui-pty.<encoded-project>.<encoded-team>.<encoded-role>.state.json`. The three keys must be encoded identically to `_actas_lock_encode`. It records schemaVersion, project, team, role, owner, PTY child PID/start token, supervisorPhase, batch, injection timestamp, and completion evidence. Message bodies are stored minimally (matching existing headless state) and are omitted from regular logs.

`supervisorPhase` and `batch.phase` are orthogonal state axes and their values must never be conflated. The former includes `STARTING`, `WAITING_FOR_IDLE`, `PREPARED`, `INJECTED`, `WAITING_FOR_RESULT`, `ACK_PENDING`, `STOPPING`, and `NEEDS_ATTENTION`. The latter consists strictly of lowercase strings matching existing ack authorization: `prepared`, `sent`, `completed`, and `uncertain`. Immediately before an ack, `batch.phase === 'completed'` and all stored `messages[].id` values are re-verified.

If the supervisor stops, terminates, or loses synchronization after reaching `PREPARED`, the batch is retained as `uncertain`; automated retries and automated acks are prohibited. Explicit recovery equivalent to existing `--action ack|replay` is provided for the TUI monitor, accompanied by batch ID and ID set verification.

## 5. Injection Prerequisites

Raw PTY bytes cannot fully determine whether the input field is empty, the model is idle, or an approval prompt is active. To prevent false positives, the initial implementation permits injection only when all of the following conditions are met:

1. The PID and start token of the child spawned by the supervisor match current records.
2. A completion marker corresponding to either the startup initialization turn or the most recent human input has been observed.
3. The latest TUI screen state exactly matches the idle prompt signature for the supported version.
4. The input buffer is verified empty, taking into account terminal-level erasures and cursor updates.
5. No signatures for permission, trust, selection UIs, slash-command pickers, active generation, or errors are present, and a complete normal idle redraw after an alternate-screen switch has been observed.
6. The supervisor holds no un-acked batch from a previous injection.

If any condition is ambiguous, the supervisor remains in `WAITING_FOR_IDLE`. Idle status must never be inferred purely from elapsed time. Under `agy 1.1.27`, normal idle consists of an empty bottom prompt `>` paired with a `? for shortcuts` footer. The trust UI displays `Do you trust the contents of this project?` with options; the permission UI displays `Requesting permission for:` with options; active generation displays `Generating...` and an `esc to cancel` footer. Rather than searching the entire screen for blacklisted terms, the supervisor verifies that the bottom rows match the measured normal idle signature. This prevents false positives when past message history contains UI phrases, while ensuring selection UIs, generation states, errors, and alternate-screen transitions are never treated as normal idle. Because real transcripts for slash-command pickers are not yet captured, they are held unless matching normal idle.

Observing normal human input immediately sets `humanInputActive = true`, pausing automatic injection. In live operation, this state clears automatically only after observing a non-idle screen once, ensuring no pending input exists on stdin or the PTY master, the measured normal idle signature remains stable across the required duration, and no unresolved batch, `manualResumeRequired`, `durableAttention`, or violations exist. An Esc keystroke that ends on stale idle display is not cleared. Restart recovery follows separate rules: temporary input pauses are cleared on a new TUI only after observing stable normal idle. Existing `manualResumeRequired = true` remains a durable latch for explicit resumption and is never cleared automatically. Any prepared batch present at shutdown causes a stop under `uncertain`.

`agy 1.1.27` operates in the alternate screen from launch to exit; being in the alternate screen is therefore not a refusal condition. Upon observing `?47`, `?1047`, or `?1049` switches, the old screen model is discarded, and injection is held until a complete normal idle redraw is re-observed. Because the bracketed paste envelope terminates with a carriage return (Enter), sending it outside normal idle risks confirming unexpected permission or selection prompts. Screen state may change while running `peek` and writing the prepared state; therefore, the normal idle signature is re-evaluated immediately before injection. If unprocessed child output remains on the PTY master or unprocessed human input exists on the parent terminal, the batch remains held in `prepared`. This prevents transmitting a trailing Enter if the screen transitions to a permission, trust, selection, or generating state after checking the model.

A completion marker from the screen parser is not sufficient on its own for an ack. The current implementation simultaneously requires a complete receipt on screen, the absence of error/cancel/interrupt signatures, no unsupported escape sequences, and confirmation that the frozen message body does not contain the complete receipt string. The receipt literal is omitted from the envelope, providing only composition rules. Blanking the envelope echo from the screen prior to ack is unimplemented due to provenance constraints described in Section 11. Any version where these conditions cannot be verified disables automatic acks and enters `NEEDS_ATTENTION`.

Target version support is locked strictly to `agy 1.1.27`. If `agy --version` differs, the supervisor aborts before launch rather than trusting unverified signatures. Adding version support requires capturing transcripts of idle, generating, drafting, permission, trust, and resume states into test fixtures.

## 6. Injection Format and Receipt Confirmation

Streaming message bodies keystroke-by-keystroke interferes with IMEs and user draft input. Bracketed paste is used to insert an explicit inbox envelope as an atomic block, followed by a single Enter sent by the supervisor:

```text
[agmsg batch id=<uuid> count=<N>]
[agmsg message id=<message-id-1>]
from: <sender-1>
at: <JST timestamp-1>
body:
<body-1>
[/agmsg message]
[agmsg message id=<message-id-2>]
from: <sender-2>
at: <JST timestamp-2>
body:
<body-2>
[/agmsg message]
[/agmsg batch]
```

To avoid corrupting terminal control sequences, the supervisor encodes control bytes into printable representations. The agent template instructs the agent to treat the envelope as a normal incoming message, replying via `send.sh ... --body -` (originally `--stdin` at the time of design) when responses are required.

Entries in `messages[]` map one-to-one with message blocks and IDs in the envelope. The supervisor cross-checks the envelope count, each ID, order, and body hash against the prepared state, refusing injection if any field mismatches.

Successful writes to the PTY do not constitute receipt confirmation. After injection, the supervisor applies child terminal escape sequences to its lightweight screen model and matches the complete receipt on screen. On narrow terminals, agy wraps a logical line across multiple physical rows; continuous rows unbroken by empty lines are concatenated and matched against the complete receipt including the UUID. However, if the frozen message body contains the complete receipt under the same rules, the supervisor fails closed and refuses to ack, as on-screen text cannot be disambiguated from message content. The receipt literal is omitted from the envelope, instructing only the composition rule: the ASCII string `AGMSG_RECEIVED`, a colon (`:`), and the batch ID without whitespace. This prevents pre-synthesizing receipts before knowing the batch UUID, though it does not guarantee cell-level un-synthesizability.

The security boundary requires that escape sequences applied to the screen model originate exclusively from the agy child. User input bytes are relayed to the PTY master without feeding the screen model, and ESC characters in external bodies are sanitized to printable representations. We trust agy's renderer not to deliberately rearrange glyphs from the envelope into a receipt line. Passing through unescaped body ESC bytes, feeding human input into `screen.feed()`, or mingling non-agy output across this boundary is strictly prohibited.

Observing human input after injection generally triggers `NEEDS_ATTENTION` and prevents automated acks. As an exception, when a measured permission or trust modal's footer, options, and header simultaneously match at the bottom of the screen, user confirmation keystrokes are relayed directly to the PTY. Under this exception, only `humanInputActive` is raised; `manualResumeRequired = true` is neither touched nor newly set. The current batch awaits the matching receipt and acks only after observing the complete on-screen line. Once acked and cleared, `humanInputActive` resets automatically provided live safety invariants hold. Errors, cancellations, interrupts, permissions, and pickers are inspected secondarily behind the receipt line; overwritten screen areas cannot be detected. If no receipt appears, no ack occurs. Window resizing or unsupported escape sequences during a receive turn mark the screen `uncertain` and prevent acks even if a receipt is visible. Idle-state resizing resets the screen model and idle determination, re-evaluating injection only after synchronization and a fresh idle redraw.

Permission modals are not identified solely by the trailing `esc to cancel...` line. Identification requires an adjacent `↑/↓ Navigate · tab Amend...` line immediately preceding it, alongside matching headers and options. While active generation in `agy 1.1.27` shares the trailing footer, the line above it contains `>` and horizontal borders rather than navigation hints. Thanks to this screen layout, incoming bodies containing permission phrases or navigation hints will not trigger confirmation relay while generating chrome is visible. Using newer agy releases requires capturing real screen outputs to re-validate this heuristic.

In `agy 1.1.27`'s `Read` displays, `CSI ?5W` (DECST8C, 8-column tab stop initialization) and `CSI Z` (CBT, backward tab) appear. The screen model handles only these two sequences as default tab stops. Any other `W`, private `Z`, or unhandled escape sequence leaves the screen `uncertain` and inhibits receipt acks.

This mechanism does not guarantee that the model processed the task. An agmsg ack certifies only that the TUI completed the reception turn.

## 7. Interaction with Human Input and Collision Behavior

Human input is always forwarded to the PTY with top priority; the supervisor never cancels, rewrites, or delays user keystrokes. If the user presses any key while an external batch is in `PREPARED` or `WAITING_FOR_IDLE`, idle detection is invalidated and `humanInputActive = true` is set. Neither `supervisorPhase` nor batch phase is altered. The temporary pause clears only after meeting both non-idle re-observation for live paths and stable idle conditions. The pause is never cleared while `manualResumeRequired = true`, `durableAttention = true`, unresolved batches, or violations persist.

Observing any human input bytes during `INJECTED` or `WAITING_FOR_RESULT` transitions the batch to `uncertain` and moves the supervisor to `NEEDS_ATTENTION`. The sole exception is confirmation input matching the measured permission/trust modal at the bottom of the screen. Inputs are forwarded to the TUI, and `humanInputActive = true` pauses subsequent batches. If an incoming body contains an isolated `>` line followed by `? for shortcuts`, distinguishing body text from screen chrome becomes impossible; thus, the supervisor sets `manualResumeRequired = true` post-ack to halt further batches. This hold remains active as long as `manualResumeRequired = true`, `durableAttention = true`, unresolved batches, or violations persist. Because keystrokes may include Ctrl-C, Esc, or Enter, input absent modal verification must not be mistaken for normal turn completion.

Candidate batches arriving while the user is typing are not signaled via terminal bells, off-screen logs, or prompt annotations. Preserving conversation and TUI integrity takes precedence; paused delivery is noted without message bodies on the terminal status line.

Detecting permission or trust prompts holds the batch until the user resolves or cancels the prompt in the TUI. The supervisor never automatically emits confirmation keys, Y/N, Esc, or Enter. Detecting these prompts after `INJECTED` marks the batch `uncertain`. Unhandled screen mutations transition to `NEEDS_ATTENTION`, allowing a human to ack or replay the batch via recovery commands.

Active reservations forbid bare `$agmsg`, `inbox.sh`, and `check-inbox.sh` for regular message consumption. The template directs TUI monitor sessions to use non-acknowledging `tui-monitor status` instead. This status command reports only IDs, senders, and timestamps of prepared batches held by the supervisor, omitting bodies. If an agent or human invokes standard inbox commands and logs a read-denied event, it is treated as a secondary writer attempt and latches a violation. The supervisor transitions to `NEEDS_ATTENTION` and refuses to ack, upholding the same read-guard guarantees as headless mode.

If the supervisor exits after latching a read-denied violation, recovery requires explicitly running `agy-tui reset-guard --team <team> --name <role>`. This command clears the violation latch only when the state's project/team/role match, no batch exists regardless of phase, no reservation (including stale reservations) exists for the identity, the TUI supervisor is inactive, and actas exclusivity is acquired. Foreign or corrupted reservations (such as headless bridges) are rejected. Unread messages and ack states are untouched. Mismatched preconditions fail closed; regular `resume` cannot substitute for reset-guard.

## 8. Startup, Teardown, and Mode Changes

Pre-flight checks verify role registration, monitor markers, TTY presence, `agy 1.1.27`, PTY backend availability, existing reservations, and unresolved batches. If any check fails, agy does not start.

If `delivery.sh set turn|off antigravity <project>` detects an active TUI supervisor, it fails without terminating the TUI externally. Users run `antigravity-tui-monitor.sh resume` after ensuring the input field is cleared, or `antigravity-tui-monitor.sh stop --project ... --team ... --name ...` to shut down the TUI explicitly. Batches interrupted by stop remain un-acked in state storage. Headless bridges and TUI supervisors share the same reservation namespace and mutually refuse concurrent startup.

Clean shutdown stops new `peek` operations, ensures no turn is active, sends EOF to the child, and awaits termination. Sending kill signals after a timeout is permitted only when the target process matches the recorded child PID and start token. Reservations and actas locks are released only after verifying ownership. `antigravity-mode.mjs status` distinguishes headless and TUI PTY runtimes by name, identifying active supervisors prior to mode changes.

## 9. Implementation Map

| File | Purpose |
|---|---|
| `scripts/drivers/types/antigravity/antigravity-tui-monitor.sh` | Explicit startup, TTY/Linux pre-flight checks, supervisor execution |
| `scripts/drivers/types/antigravity/antigravity-tui-supervisor.py` | Python PTY handling, version-locked `TerminalScreen` parser, input relay, batch state, teardown |
| `scripts/drivers/types/antigravity/inbox-transport.sh` | Verifies capability/reservation handling for `peek`/`ack` or minimal TUI status additions |
| `scripts/drivers/types/antigravity/_delivery.sh` | Monitor launch instructions; rejects mode switching to turn/off when an active TUI is detected |
| `scripts/drivers/types/antigravity/antigravity-mode.mjs` | Distinguishes headless and TUI PTY status, reporting active TUIs before mode transitions |
| `scripts/drivers/types/antigravity/template.md` | In-session guidance for reception, replies, and permissions under TUI monitoring |
| `tests/antigravity_tui_supervisor.test.mjs` | State machine validation using synthetic PTY/TUI transcripts |

`antigravity-bridge.mjs` retains its existing headless-only behavior. Sharing between the headless bridge and TUI supervisor is strictly limited to reservations, atomic state writes, and transport primitives, avoiding mingling stream-json and terminal transcripts in the same parser.

## 10. Verification Plan

1. In synthetic PTY tests, bracketed paste and a single trailing Enter are emitted only when the idle signature matches completely.
2. In-progress input, active generation, permissions, trust dialogs, pickers, and unrecognized screens hold candidate batches. Resizing while idle re-initializes the screen model, verifying size parity and fresh idle output before resuming injection; resizing during a receive turn marks the batch `uncertain` and prevents an ack.
3. Post-injection human input, errors, cancellations, interrupts, or missing completion signatures mark the batch `uncertain`, inhibiting automatic acks and retries.
4. Correct state sequencing: `peek → batch.phase=prepared → sent → completed → ack`, decoupling from supervisorPhase, and restricting acks strictly to stored IDs.
5. Batch envelopes up to 20 messages match IDs, bodies, senders, and timestamps one-to-one, rejecting count, hash, or ID discrepancies.
6. Read-denied events from bare `$agmsg`/inbox paths latch violations, causing the supervisor to withhold acks and enter `NEEDS_ATTENTION`. Status commands do not mark messages read.
7. Headless bridges and TUI supervisors mutually refuse concurrent execution without regressions in `tests/antigravity_bridge.test.mjs` and `tests/test_delivery.bats`.
8. Attempting to switch delivery mode with an active TUI fails closed, updating rulefiles only after explicit stop. Headless and TUI statuses are distinguished. Stale idle output, sub-threshold intervals, unresolved batches, `manualResumeRequired`, `durableAttention`, and violations hold injection. Pauses clear automatically only after observing live non-idle followed by stable idle, or upon restart after fresh idle observation. Acknowledged permission/trust flows preserve receipts, restoring automatic delivery once batches clear.
9. Real machine verification using disposable projects, separate roles, and targeted bodies: verifies idle reception, context retention, human keystroke relay, input hold, permission hold, stop/restart, and replies to senders.
10. Preserves screenshots and raw PTY transcripts on real hardware, verifying child PID/start token, conversation ID, terminal attachment, and receipt arrival.

During isolated testing on 2026-09-06 using `/tmp/agmsg-agy-screen-e2e-np6JfK/project`, isolated SQLite, and `agy 1.1.27`, batch `46e6cd17-ccca-4dae-8a91-da567d993adc` verified post-trust resumption, injection, reconstructed receipt detection from differential rendering, acking, and `No new messages.` on stop. Child PID was `3867910`, start token `3820534`, stdin `/dev/pts/6`, and raw transcript saved to `/tmp/agmsg-agy-screen-e2e-np6JfK/raw-pty.transcript`. Replaying the transcript in 67-byte chunks reconstructed the receipt line without trailing unknown escape sequences. Capturing conversation IDs and screenshots remains an open requirement.

Design changes and code land in the same commit, submitted for independent review only after passing synthetic PTY tests, isolated end-to-end runs, and real hardware TUI tests. Pushing depends on review outcomes.

## 11. Open Items

- Real transcripts for slash-command pickers are not yet captured. Idle, trust, permission, and generation states are frozen in `tests/fixtures/agy-1.1.27-screen-transcripts.json`.
- Erasing echoed envelopes from the screen model prior to ack is unimplemented. The lightweight screen model preserves only final cells, lacking per-character provenance ("envelope text" vs "model reply"). Line wrapping, redraws, and cursor repositioning prevent safe erasure without stronger evidence. The current boundary relies on omitting receipt literals from envelopes, rejecting identical receipts in message bodies, and marking unknown escape sequences uncertain.
- A future alternative involves line-by-line screen snapshotting immediately post-injection, filtering unchanged rows during ack evaluation. While promising for persistent pre-existing receipt lines, its efficacy when agy redraws the full screen is unverified; it requires evaluation on isolated hardware before introducing provenance tracking.
- Section 5 Condition 5 avoids global keyword blacklists. It relies strictly on bottom-row idle signatures; permission, trust, generation, picker, error, and transition states are held unless matching normal idle. Capturing slash-command picker transcripts remains necessary before broadening version coverage. Narrow terminal support (40x24) is captured; right-hand status in `agy 1.1.27` wraps physically. Bottom-row heuristics evaluate logical rows within measured limits (64 cells) and must be re-captured for future releases.
- Cross-terminal discrepancies, IMEs, tmux/SSH, and alternate-screen edge cases.
- Confirming whether alternate-screen redraws produce identical escape sequences across different terminal emulators.
- Availability risk: if agy uses unhandled IL/DL, SU/SD, DECSTBM, DSR, or DA sequences during a receipt turn, the supervisor halts safely, preventing acks.
- Determining how aggressively to prompt users to restart via the monitor wrapper when `agy` is launched directly.

These items are decided during pre-implementation reviews. Loosening signatures or introducing best-effort injection into unmanaged TUIs while items remain open is prohibited.
