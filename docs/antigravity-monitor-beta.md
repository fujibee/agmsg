# Antigravity TUI Monitor

Antigravity (`agy`) does not expose Claude Code's Monitor tool. agmsg's Antigravity
monitor delivers incoming messages into the **TUI conversation you are actually
talking to**, by running `agy` under a PTY supervisor that injects message
envelopes into its input and waits for the model to acknowledge them.

> ⚠️ **This changes how `agy` runs, and it deliberately stops delivering in
> several situations — read before enabling.**
>
> The supervisor owns the PTY that `agy` runs on. It relays your keystrokes
> through to `agy` unchanged, but it also injects text of its own. To avoid
> corrupting what you are typing, it **stops delivering** whenever it cannot
> prove the input area is empty and idle — including after **any** keystroke you
> make. Resuming is a manual, explicit act (see
> [Pause and resume](#pause-and-resume)).
>
> It is Linux-only in this first version, and pinned to the `agy` version whose
> screen output was actually measured (see
> [Known limitations](#known-limitations)). It depends on `agy`'s terminal
> rendering and may need updating as Antigravity changes.

## Why a PTY supervisor

The obvious approach — connect a second, headless `agy` process to the same
conversation ID — was tried and **rejected on measurement**: a headless turn
against the same conversation ID does **not** update the live TUI's in-memory
context. The model answered from its old context, so the message never reached
the conversation the human was using.
(`docs/design/antigravity-conversation-registration.md` records the experiment.)

Driving the real TUI through its PTY is what actually reaches the live
conversation. That is the reason for the complexity in this driver.

## Quick Start

```bash
# 1. Enable monitor delivery for a project.
~/.agents/skills/agmsg/scripts/delivery.sh set monitor antigravity "$(pwd)"

# 2. Start agy under the supervisor, from an interactive terminal.
agy-tui

# 3. Check what the supervisor thinks is going on, from anywhere.
agy-tui status --project "$(pwd)" --team <team> --name <role>
```

`agy-tui` is a small wrapper installed at `~/.agents/bin/agy-tui`. With no
arguments it resolves `--project` from the current directory and resolves
`--team` / `--name` from the single Antigravity identity registered for that
project; it refuses (fail-closed) if zero or several are registered. Pass them
explicitly when the project has more than one.

```
Usage: agy-tui [status|stop|resume|reset-guard|ack|replay] [--project <path>] [--team <team>] [--name <role>] [--agy <path>] [monitor options...]
```

`status`, `stop`, `resume` and `reset-guard` work from a non-interactive shell
and do not need `agy` on `PATH`. Only the default `run` action requires a TTY.

## Reading `status`

```
runtime: <role> tui-pty running     # supervisor alive, nothing in flight
runtime: <role> tui-pty busy        # a batch is injected, waiting for the receipt
runtime: <role> tui-pty paused      # auto-delivery is temporarily or durably paused; see below
runtime: <role> tui-pty 停止/要確認  # the recorded process is gone
runtime: tui-pty 未起動              # no supervisor is registered for this identity
```

When a batch is in flight, `status` also prints the batch id, its phase, and one
line per message with `id` / `from` / `at`. **It never prints message bodies**, so
it is safe to paste into a bug report.

## Pause and resume

When you type outside an injected receive turn, the supervisor immediately
pauses delivery and prints this once to its own stderr:

```
[agmsg] 人間の入力中は自動配送を保留します。空の入力待ちに戻れば自動再開します
```

This is deliberate, not a failure. Live delivery resumes only after the
supervisor first observes a non-idle screen, then observes the supported empty
idle prompt continuously with no pending terminal input or output. An unresolved
batch, a durable attention condition, or the legacy manual-resume latch prevents
automatic resume. An Esc that leaves the old idle screen visible therefore stays
paused because no non-idle redraw was observed.

An ordinary-input pause is written to the state file. After a supervisor restart
it can clear only after the newly launched TUI renders the supported empty idle
prompt; the live-session requirement to first observe non-idle does not apply to
this restart path. An ordinary-input pause needs no command: finish the human
turn and return to the empty input prompt, and the supervisor resumes delivery
after the safety checks above pass. Durable attention and legacy
`manualResumeRequired` states are never cleared automatically. Clear the input
box before explicitly clearing a durable manual pause. The same `resume` command
can clear an ordinary-input pause, but that is normally unnecessary because the
ordinary pause resumes automatically:

```bash
# From inside the agy TUI (Antigravity uses the "$" prefix, not "/"):
$agmsg resume

# Or from any shell:
agy-tui resume --project <path> --team <team> --name <role>
```

`resume` clears only the manual-resume and ordinary-input pause. It does not
clear a durable attention/read-denied condition; use the reported recovery path
for that condition.

The same latch is set after a delivered message contains a standalone `>` line
followed by `? for shortcuts`: copied screen text can otherwise be
indistinguishable from the footer in the lightweight terminal model. Handle the
visible dialog, confirm the input box is empty, then resume explicitly.

## ⚠️ Do not run the normal inbox commands while monitor is on

**This is the mistake people actually make.** While a TUI monitor holds a
reservation for an identity, running any of these:

- a bare `$agmsg` (whose default action is an inbox check)
- `inbox.sh`
- `check-inbox.sh`

trips agmsg's read guard. The guard records a `read-denied` violation, the
supervisor sees it, refuses to acknowledge the in-flight batch, and **stops**:

```
通常inboxによる既読試行を検知; ackせず停止します
復旧: 入力欄を空にしてから `agy-tui reset-guard --project <project> --team <team> --name <role>` を実行してください
```

Nothing is lost — the messages stay unread — but delivery is down until you
recover.

The guard is intentionally not relaxed for the human case. agmsg cannot tell a
curious human apart from a buggy second writer, and the whole point of the guard
is that only one writer marks messages read. Use `agy-tui status` when you want
to see what is pending; it reads without marking anything.

## Recovering: which command do I need?

These recovery paths are **not** interchangeable. First distinguish an ordinary
input pause from a durable pause or an unresolved batch.

| Symptom | Cause | Recovery |
|---|---|---|
| `通常inboxによる既読試行を検知` | a `read-denied` violation is latched | `agy-tui reset-guard …` |
| A batch is stuck in `uncertain` / `NEEDS_ATTENTION` | the turn could not be verified | `agy-tui ack …` or `agy-tui replay …` |
| `paused` after ordinary typing | `humanInputActive`; the supervisor is waiting for a safe idle transition | No command. Finish the human turn and return to the empty input prompt; delivery resumes automatically after the non-idle and stable-idle checks pass. |
| `paused` with a durable manual-resume latch | `manualResumeRequired`; automatic resume is deliberately disabled | Clear the input box, then run `$agmsg resume` or `agy-tui resume …`. |

`reset-guard` only clears the violation latch, and only when there is nothing to
acknowledge: it refuses if a batch is still recorded (**any** phase), if a
supervisor for that identity is alive, if the reservation looks corrupt, or if it
cannot take the identity's exclusivity lock. It never marks messages read.

For a stuck batch, choose by **whether the model actually read the messages**:

- The model produced the `AGMSG_RECEIVED:` line and answered → the work is done,
  only the bookkeeping failed. Use `agy-tui ack`.
- The model never saw them → use `agy-tui replay`, which re-injects the same
  batch.

Both take `--batch <id>` and repeated `--confirm-id <message-id>` and verify the
id set before doing anything.

> ⚠️ **Before `replay`, look at the screen.** Receipt matching scans the
> reconstructed screen, and `replay` reuses the *same* batch id and receipt
> string. If an old `AGMSG_RECEIVED:<that batch id>` line is still visible — for
> example because `agy` redrew earlier conversation history — the supervisor can
> match it and acknowledge without the model reading anything. Clear the screen,
> or use `ack` if the model demonstrably already answered.
>
> The permanent fix for this is listed under
> [Known limitations](#known-limitations).

## Permissions for `agy`

`agy` asks for confirmation before running commands. Every prompt while a batch
is pending is a prompt that blocks delivery, so allow the agmsg scripts your role
actually uses in `~/.gemini/antigravity-cli/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "command(/home/you/.agents/skills/agmsg/scripts/send.sh)",
      "command(bash /home/you/.agents/skills/agmsg/scripts/send.sh)",
      "command(/home/you/.agents/skills/agmsg/scripts/identities.sh)",
      "command(bash /home/you/.agents/skills/agmsg/scripts/identities.sh)"
    ]
  }
}
```

Two things that cost real debugging time:

- **Write absolute paths.** A `~`-prefixed entry such as
  `command(~/.agents/skills/agmsg/scripts/identities.sh)` does **not** match, so
  the prompt keeps appearing while the entry looks present. This was measured
  after a permission dialog for `identities.sh` collided with an injection and
  stopped the supervisor.
- **Do not allow the inbox scripts.** Allowing `inbox.sh` — especially a
  fully-specified form like
  `command(bash …/scripts/inbox.sh <team> <role>)` — removes the speed bump in
  front of the mistake described above.

Keep the list narrow otherwise. `command(gh)` allows every `gh` subcommand,
including `gh api` with `-X DELETE`; prefer read-only forms such as
`command(gh issue list)`.

## Mechanics

- **Injection gate.** The supervisor injects only when the reconstructed screen
  bottom matches a measured idle signature — the empty prompt line, then the
  `? for shortcuts` footer. Real dialogs (trust, permission, generating) put
  other chrome there, which is what keeps injections out of them. The gate is
  re-evaluated immediately before writing, and skipped if unread child output or
  unread human input is waiting.
- **Envelope.** Messages are pasted as a bracketed-paste block: one
  `[agmsg batch id=<uuid> count=<n>]` header, one `[agmsg message id=…]` block
  per message, and an instruction to emit the receipt line first. Control bytes
  in bodies are escaped. **The receipt string itself is not in the envelope** —
  the batch id is a fresh uuid4, so nobody can pre-compute the receipt.
- **Receipt and ack.** Acknowledgement requires the receipt line to appear as a
  complete line on the reconstructed screen, plus the batch phase and the exact
  id set to match what was stored. Acks go through the same
  capability/reservation checks as the headless bridge.
- **Screen model.** A small terminal emulator reconstructs the visible screen,
  because `agy` builds the receipt line with cursor movement rather than
  printing it in one piece. Alternate screen is `agy`'s normal state, so
  `?1049h/l` is treated as a state transition (old screen discarded), while
  **unknown control sequences set an uncertain flag and block acknowledgement**.

## Guardrails

Everything below fails toward "do not acknowledge". A message left unread is
recoverable; a message marked read that the model never saw is not.

- Unknown control sequences, a resize during a receipt turn, and alternate-screen
  toggles mid-turn all mark the screen uncertain and block the ack.
- Human input during a receipt turn marks the batch `uncertain` rather than
  guessing whether the turn completed.
- A body that contains the full receipt string blocks the ack for that batch,
  so text on screen cannot stand in for the model's own answer.
- `stop` sends EOF first and only signals the child if its PID *and* start token
  still match.

### Case study: a `Read` display stopped delivery (2026-09)

A live monitor injected a batch, the model emitted the receipt line, and then ran
its `Read` tool. The tool's output contained `CSI ?5W` and `CSI Z`, which the
screen model did not know, so it set the uncertain flag and refused to
acknowledge — leaving four messages in `uncertain` even though the model had
demonstrably read them.

Two separate faults were behind it: the unhandled sequences, and — in a narrow
pane — the receipt UUID wrapping across physical lines so that single-line
matching missed it. Both are fixed; the case is here because the failure looked
like "nothing is being delivered" while `status` said the supervisor was alive.
When delivery stops silently, check `status` and the batch phase first.

### Emergency stop

```bash
agy-tui stop --project <path> --team <team> --name <role>
```

This ends the supervisor and closes the `agy` child. To turn monitor delivery off
for the project entirely:

```bash
~/.agents/skills/agmsg/scripts/delivery.sh set turn antigravity "$(pwd)"
```

`set turn` / `set off` **refuse** while a TUI supervisor is alive, rather than
killing the terminal you are working in. Stop the supervisor explicitly first.

## Known limitations

- **Envelope echo is not subtracted before matching.** The receipt is matched
  against the whole reconstructed screen, so a stale receipt line elsewhere on
  screen can satisfy the check. The screen model retains final cells, not the
  provenance needed to subtract injected text safely through redraws and cursor
  movement. A future, cheaper experiment may compare rows with a snapshot taken
  immediately after injection; this is why `replay` needs the visual check above.
- **Injection-time signature checks are not implemented.** Design condition 5
  (no permission / trust / picker / generating / error / alt-screen signature
  present) is approximated by the bottom-of-screen allowlist rather than checked
  directly. The allowlist is backed by measured `agy` fixtures, not by proof.
- **The injected envelope ends with a carriage return.** Injecting into a dialog
  would therefore confirm it. Nothing sends confirmation keys deliberately, and
  the gate is meant to keep injections out of dialogs, but the two facts sit next
  to each other.
- **Screen signatures are pinned to a measured `agy` version.** Fixtures live in
  `tests/fixtures/agy-1.1.27-screen-transcripts.json`. Add a version only after
  capturing its idle / trust / permission / generating screens the same way. At 40 columns on 1.1.27, the footer's right-side status wraps in terminal cells; the measured narrow fixtures cover that geometry. Re-measure this for every added version.
- **The slash-command picker screen was never captured**, so it is not
  recognised specifically; it is only excluded because it does not match the
  idle signature.
- **Linux only**, and `python3` is required for the supervisor.
- **The input box is never proven empty.** The manual-resume latch exists because
  of this, and removing the latch would reintroduce draft corruption.

## Related details

- `docs/design/antigravity-tui-pty-monitor.md` — the design, the measurements it
  rests on, and the open items above.
- `docs/design/antigravity-monitor-bridge.md` — the headless bridge, still used
  for `standalone` operation.
- `docs/design/antigravity-conversation-registration.md` — the rejected
  same-conversation approach, kept as a record of what was measured.
- `docs/codex-monitor-beta.md` — the same idea for Codex, via an app-server
  bridge instead of a PTY.
