# Antigravity TUI Monitor

> **Status: experimental.** Usable only on a dedicated seat that no person
> types into. Start it as:
>
> ```bash
> agy-tui --team <team> --name <role> -- --dangerously-skip-permissions
> ```
>
> `--dangerously-skip-permissions` means every `agy` tool call for the rest of
> that session runs unconfirmed — including one triggered by a message this
> driver injects. That flag is the only known way around the permission-prompt
> failure mode in [Known limitations](#known-limitations) below; it is not a
> convenience. For a seat a person actually types into, use the default `turn`
> delivery instead (already the default in setup) — do not run the TUI monitor
> there.

The long-term direction is delivery through agmsg's terminal driver
integration — the same mechanism this skill already uses to reach other
CLIs — rather than a PTY supervisor built specifically for Antigravity.

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
> It supports Linux and macOS (Windows is refused — no POSIX PTY), and is
> pinned to the `agy` version whose screen output was actually measured (see
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

**Monitor delivery only happens through `agy-tui`.** Plain `agy`, started any
other way, is ordinary Antigravity with no agmsg delivery at all — the
supervisor is `agy-tui`'s PTY wrapper, and nothing else runs it or injects
into it.

`agy-tui` is a small wrapper installed at `~/.agents/bin/agy-tui`. That
directory has to be on `PATH` for the bare `agy-tui` command above to resolve
(agmsg's installer adds it; confirm with `command -v agy-tui`, or invoke
`~/.agents/bin/agy-tui` by its full path if it is not on `PATH`). With no
arguments it resolves `--project` from the current directory and resolves
`--team` / `--name` from the single Antigravity identity registered for that
project; it refuses (fail-closed) if zero or several are registered. Pass them
explicitly when the project has more than one.

```
Usage: agy-tui [status|stop|resume|reset-guard|ack|replay] [--project <path>] [--team <team>] [--name <role>] [--agy <path>] [-- agy options...]
```

Anything after `--` is passed to the real `agy` process unchanged, for
example `agy-tui --team T --name R -- --dangerously-skip-permissions`.
`agy-tui` never adds that flag on its own — see
[Permissions for `agy`](#permissions-for-agy) for when it is worth reaching
for.

`status`, `stop`, `resume` and `reset-guard` work from a non-interactive shell
and do not need `agy` on `PATH`. Only the default `run` action requires a TTY.

## Reading `status`

```
runtime: <role> tui-pty running     # supervisor alive, nothing in flight
runtime: <role> tui-pty busy        # a batch is injected, waiting for the receipt
runtime: <role> tui-pty paused      # auto-delivery is temporarily or durably paused; see below
runtime: <role> tui-pty stopped/needs-attention  # the recorded process is gone
runtime: tui-pty not started                     # no supervisor is registered for this identity
```

When a batch is in flight, `status` also prints the batch id, its phase, and one
line per message with `id` / `from` / `at`. **It never prints message bodies**, so
it is safe to paste into a bug report.

## Pause and resume

When you type outside an injected receive turn, the supervisor immediately
pauses delivery and prints this once to its own stderr:

```
[agmsg] Automatic delivery is paused while a person is entering input. It will resume when the empty input prompt returns
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
detected a mark-read attempt through the regular inbox; stopping without ack
Recovery: clear the input field, then run `agy-tui reset-guard --project <project> --team <team> --name <role>`
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
| `detected a mark-read attempt through the regular inbox` | a `read-denied` violation is latched | `agy-tui reset-guard …` |
| A batch is stuck in `uncertain` / `NEEDS_ATTENTION` | the turn could not be verified | `agy-tui ack …` or `agy-tui replay …` |
| `paused` after ordinary typing | `humanInputActive`; the supervisor is waiting for a safe idle transition | No command. Finish the human turn and return to the empty input prompt; delivery resumes automatically after the non-idle and stable-idle checks pass. |
| `paused` with a durable manual-resume latch | `manualResumeRequired`; automatic resume is deliberately disabled | Clear the input box, then run `$agmsg resume` or `agy-tui resume …`. |
| A real `agy` permission dialog appears while a batch is in flight (`WAITING_FOR_RESULT`) | agy 1.2.5's permission screen is not a recognized shape; the keypress you send it marks the batch `uncertain`, sets durable attention, and **stops the supervisor** | This is the same stuck-batch case above, not an ordinary pause: run `agy-tui status`, then `agy-tui ack` or `agy-tui replay` with `--batch <id>` and `--confirm-id <message-id>` for each pending message, then start the supervisor again. An empty input prompt does not bring it back on its own. Prefer `--dangerously-skip-permissions` (status box at the top) to avoid triggering this at all. |
| A Python traceback after running `replay` | the batch `replay` was pointed at was already cleared by an earlier `ack` | Nothing to run — the message was already handled. Confirm with `agy-tui status`; do not re-run `replay`. |
| `could not uniquely identify a TUI supervisor to stop or resume` | no supervisor is currently running for that identity | Run `agy-tui status` first to confirm whether one is expected to be there. |

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
      "command(bash /home/you/.agents/skills/agmsg/scripts/identities.sh)",
      "command(/home/you/.agents/skills/agmsg/scripts/whoami.sh)",
      "command(bash /home/you/.agents/skills/agmsg/scripts/whoami.sh)",
      "command(bash -lc '~/.agents/skills/agmsg/scripts/whoami.sh \"$(pwd)\" antigravity')"
    ]
  }
}
```

Two things that cost real debugging time:

- **Write every invocation shape you actually use, `~` and absolute alike.**
  `command(...)` matches the command string as written, so a bare-path entry
  and a `bash `-prefixed entry for the same script are two different rules —
  both are needed if the agent ever invokes the script both ways, the same
  reasoning as the Claude Code permission guidance elsewhere in this skill. An
  older version of this doc claimed a `~`-prefixed entry never matches; that
  was re-measured on 2026-09-17 against agy 1.2.5 in headless `agy -p` mode
  and does not hold: a bare `command(~/.agents/skills/agmsg/scripts/<x>)` rule
  let a bare invocation of `<x>` run with no prompt, while a real negative
  control — the identical command with no allow-rule at all — was auto-denied
  with an explicit "a tool required the 'command' permission that headless
  mode cannot prompt for" message, confirming the allow-list was genuinely
  being enforced rather than bypassed by print mode. What did trip the match
  was the invocation *shape*, not the `~`: that same bare `~`-form rule did
  not cover a `bash ~/...`-prefixed invocation of the identical script, and
  needed its own separate entry before that shape matched too. Absolute paths
  stay the simpler default because they sidestep reasoning about `~`
  expansion at all — but a `~`-prefixed rule is not the dead end this doc used
  to say it was.
- **A `bash -lc '...'` wrapper is a third shape, and it needs the whole
  command as its pattern.** An agmsg command containing shell syntax that
  cannot pass through argv alone — `"$(pwd)"` in particular — gets wrapped
  and prompted as `bash -lc '<the command, unexpanded>'` (for
  example `bash -lc '~/.agents/skills/agmsg/scripts/whoami.sh "$(pwd)"
  antigravity'`), and neither the bare-path nor the `bash <path>` entry
  above covers that. The fix, re-measured the same way: an allow-rule that is
  the *entire* `bash -lc '...'` string, quoting and all, exactly as shown in
  the JSON above, does match — and a real negative control (the same wrapper
  around an unrelated command) confirmed it wasn't already passing through
  for some other reason. **Do not shorten the rule to just
  `command(bash -lc)`.** That bare prefix was also measured, against a real
  negative control: it matched *any* `bash -lc '<anything>'` command,
  agmsg-related or not — the same hazard as the bare `command(gh)` warning
  below, just for the interpreter instead of a program name. Keep the whole
  wrapped string as the rule.
- **Do not allow the inbox scripts.** Allowing `inbox.sh` — especially a
  fully-specified form like
  `command(bash …/scripts/inbox.sh <team> <role>)` — removes the speed bump in
  front of the mistake described above.

Keep the list narrow otherwise. `command(gh)` allows every `gh` subcommand,
including `gh api` with `-X DELETE`; prefer read-only forms such as
`command(gh issue list)`.

### `--dangerously-skip-permissions`

The narrow allow-list above is the general-purpose way to stop permission
stalls for `agy` — it only lets through the exact agmsg commands this driver
actually runs, and is worth building out for any use where a stalled prompt
merely delays a turn.

For the experimental **monitor** seat specifically, this flag is the practical
requirement today, not a last resort held in reserve: `agy` asks for
permission in varying invocation shapes (see [Permissions for
`agy`](#permissions-for-agy) above), an allow-list can only ever cover the
shapes it was actually built against, and — unlike an ordinary CLI turn — a
prompt the supervisor does not recognize during a delivery does not just
stall, it **stops the supervisor entirely** with an uncertain batch (see
[Known limitations](#known-limitations)). `agy-tui`'s `--`
[pass-through](#quick-start) starts `agy` with it directly:

```bash
agy-tui --team <team> --name <role> -- --dangerously-skip-permissions
```

State the trade-off to yourself before reaching for this: it does not narrow
anything, it removes confirmation entirely. Every shell and tool call agy makes
for the rest of that session runs unconfirmed — not just agmsg's — including
ones triggered by a message this driver injects. `agy-tui` never adds this
flag on its own; it is something you choose per-session, not a default.

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
- **Linux and macOS**; Windows is refused (no POSIX PTY), and `python3` is
  required for the supervisor.
- **The input box is never proven empty.** The manual-resume latch exists because
  of this, and removing the latch would reintroduce draft corruption.
- **A keystroke while idle pauses delivery; the same keystroke while a batch is
  in flight stops the supervisor — these are two different outcomes, not one.**
  While idle (no batch injected), typing pauses delivery the same way as any
  other keystroke, and it resumes automatically once the input goes back to
  empty; see [Pause and resume](#pause-and-resume). While a batch is in flight
  (`WAITING_FOR_RESULT`) and the keypress is not a recognized permission-screen
  shape, the supervisor cannot tell it apart from unexpected human interference
  mid-delivery: it marks the batch `uncertain`, sets durable attention, and
  **stops** — it does not merely pause, and an empty prompt does not bring it
  back. This second case is what makes a shared, interactively-used seat not
  what this driver is for today.
- **A real permission dialog during a delivery is exactly the second case
  above.** Observed with agy 1.2.5: its permission screen is not one of the
  recognized signatures, so the keypress you send it stops the supervisor with
  an uncertain batch — see the recovery table below.
  `--dangerously-skip-permissions` (status box at the top) is the only known
  way to avoid triggering this at all, which is why it is the practical
  requirement for the experimental monitor seat today, not merely a
  last-resort option.
- **After a stop, the next start refuses until a person runs `ack` or `replay`
  for the uncertain batch, and `replay` run right after `ack` prints a Python
  traceback.** Observed: `ack` completes and clears the batch; a `replay`
  invoked afterward for the same (now-cleared) batch id finds nothing to
  replay and exits with an unhandled traceback rather than a plain error.
  Treat the traceback as "already ack'd, nothing to replay" and move on —
  do not re-run `replay` expecting a different result.
- **State from a previous run can make the next start come up paused.** A
  `humanInputActive`, `manualResumeRequired`, or durable-attention flag left in
  the state file at the end of one run is still there at the start of the
  next; the new process comes up already paused for a reason that has nothing
  to do with anything it has done yet.
- **The pause-resume hint can be overdrawn by the agy screen.** The line
  telling you delivery is paused and how to resume is printed to the
  supervisor's own stderr once, at the moment it becomes true; if `agy`
  redraws its screen afterward, that redraw can cover the hint in whatever
  terminal you are watching. Absence of the hint on screen is not evidence
  delivery is not paused — check `agy-tui status` instead.
- **`resume` fails with `could not uniquely identify a TUI supervisor to stop
  or resume` when no supervisor is running for that identity.** This is not a
  bug in the identity lookup: there is genuinely nothing to resume. Run
  `agy-tui status` first to confirm whether one is expected to be there.

## Related details

- `docs/design/antigravity-tui-pty-monitor.md` — the design, the measurements it
  rests on, and the open items above.
- `docs/design/antigravity-monitor-bridge.md` — the headless bridge, still used
  for `standalone` operation.
- `docs/design/antigravity-conversation-registration.md` — the rejected
  same-conversation approach, kept as a record of what was measured.
- `docs/codex-monitor-beta.md` — the same idea for Codex, via an app-server
  bridge instead of a PTY.
