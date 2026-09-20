# ext-tool — an external program as a team member

`ext-tool` is an agent type whose member is a program rather than a CLI agent.
It joins a team like anyone else, and a message addressed to it *is* the call:
the team's messages are the interface.

> ⚠️ **Experimental. The interface and the architecture will change.**
> ext-tool ships as a preview so the adapter contract can be exercised against
> real tools. Two things are already decided and will land later: message
> delivery moves into a daemon (`agmsgd`), and the invocation you see here
> becomes a *delivery mode* owned by that daemon rather than something the
> sending command does. Treat every path and flag on this page as unstable.
>
> **We are not taking external adapter contributions yet.** Please open an
> issue describing the tool you want to connect — that feedback shapes the
> contract — but hold the pull request until this page drops the warning.

## Why a member and not a tool call

A tool call belongs to one agent's session. It is invisible to the rest of the
team, absent from the team's history, and configured separately in every
runtime. A member is addressable:

- **The exchange is on the record.** The request and the reply are ordinary
  messages. Anyone on the team — including a human reading later — sees what
  was asked and what came back.
- **One address, every runtime.** Claude Code, Codex, and any other seat send
  to the same name. There is nothing to install per runtime.
- **Credentials live in one place.** The key sits with the tool's member
  config, not in each agent's settings.
- **Delegation, not invocation.** The sender does not block. An adapter may
  take its time and the reply arrives as a message.
- **People and programs share one namespace.** A channel of humans and a
  decision model are both just members.

## Joining a tool

```bash
agmsg join <team> <name> ext-tool --tool <tool>
```

Adapters ship under `scripts/drivers/ext-tools/<tool>/`. Two are bundled:
`slack` (post to one channel) and `jev` (ask TypeSafe's Jev decision model,
through OpenRouter, for a typed decision).

If the member has no configuration yet, `join` refuses and points at the
adapter's `SETUP.md`. That file is written for the agent at the keyboard: it
walks the person through creating the app, installing it, storing the secret,
and running a live check, one step at a time. The setup commands themselves
never prompt, so the same path works by hand or in CI:

```bash
agmsg ext-tool setup  <team> <name> <tool> status|check <item>|save|test
agmsg ext-tool secret <team> <name> [--from-clipboard]
```

`secret` reads the value from a terminal, or from the clipboard when the agent
cannot be given a TTY, writes it mode 600, and reports only the path it wrote
to. The value never reaches the chat, the message history, or a log.

## Asking a member well

Each adapter ships a `USAGE.md` written for the agent that sends to it: what the
member does, the shape it accepts, copyable examples, what it refuses, and the
knowledge that makes an answer better rather than merely valid. Read it before
the first message:

```bash
agmsg ext-tool usage <team> <name>
```

A refusal always names that command, so a badly shaped request corrects itself
in one round trip.

Adapters declare how strict they are, in `tool.conf`:

- `request=strict` — the body must already be the call. The adapter does not
  interpret; it refuses and points at `USAGE.md`. `jev` is strict, because
  being fast and cheap is the point.
- `request=loose` — a plainly worded request is acceptable. `slack` is loose.

## The adapter contract

An adapter is any executable. agmsg speaks to it through stdin, stdout, and
the exit status:

| | |
|---|---|
| stdin | one JSON object: `team`, `from`, `to`, `body`, `question?`, `message_id`, `config_path` |
| stdout | the reply body. Empty means "send no reply" |
| exit 0 | success |
| exit non-zero | failure; agmsg sends one named line back to the sender |
| timeout | `tool.conf`'s `timeout=`; on expiry the process group is stopped and the sender is told |

Everything else is the adapter's own business: `tool.conf` declares its
required configuration keys, `setup` validates and saves them, `SETUP.md`
teaches the agent how to guide a person through it.

A failure is never silent. A missing config, an unknown tool name, a timeout,
or a non-zero exit all come back to the sender as one line.

## Bundled adapters

**`slack`** posts a message body to one configured channel. The reply is empty:
posting only. `setup test` posts a real message and returns its permalink.
Inbound Slack replies are not carried back into agmsg yet.

**`jev`** asks a typed question and answers in one line, for example:

```
route: sonnet / high (choice p=0.96, confidence=0.94, cost $0.000021)
```

The question travels with the message: a body that is JSON carrying a
`questions` object is passed through, so the agent composes the decision it
actually needs. How to phrase one well — including wording that was measured to
separate the options, and the fact that a Japanese state text drives the
probabilities toward 0.5 — is in the adapter's `USAGE.md`.

## What this preview does not do

- **Only a message sent from this machine triggers the adapter.** A message
  that arrived here through remote sync does not, because invocation currently
  hangs off the send path. This is the main reason the daemon takes it over.
- **The adapter runs on the sender's machine**, not on the machine where the
  member was joined. For a tool that only talks to a remote service this is
  invisible; for one that touches local state it is not.
- **One installation per tool member — by convention, not by enforcement.**
  Joining the same tool name from two installations delivers to both, and both
  run it. Nothing prevents that today and the daemon will not either: separate
  installations are separate worlds. Keep a tool joined in one place; an
  exclusivity service is a later question, not a v1 promise.
- **A tool cannot speak first.** Adapters answer; they do not start a
  conversation. Carrying Slack replies back into a team needs that.
- **No retries and no ordering guarantees.** A failed call is reported, not
  retried.
- **No synchronous form.** There is no call that returns the answer inside the
  same command; the reply arrives as a message.

## Where it is going

When `agmsgd` owns delivery, invoking an adapter becomes one more way to
deliver a message to a member — the same layer that streams to a Claude Code
seat or pokes a terminal. Everything in the list above is then a property of
delivery rather than a special case: a message that arrives by sync is
delivered like any other, the same message is not run twice within an
installation, and retries, ordering, and bounded failure belong to the loop.
What it will not do is reconcile two installations that joined the same tool —
that stays a matter of how you set the team up.

**The adapter contract above is meant to survive that move.** The invoker
changes; stdin, stdout, the exit status, and the timeout do not.

Two design decisions follow the same line:

- **An adapter may call a model, once.** Turning a natural-language request
  into a specific API call, or a raw result into a readable line, is a job for
  a model, and a headless one-shot call is enough. It stays opt-in per tool and
  bounded.
- **Anything that carries context between messages is a seat, not a tool.**
  If the work needs memory of the last exchange, retries of its own, or several
  turns of judgement, spawn an agent. ext-tool stays "one message in, one reply
  out".

## MCP

MCP and ext-tool answer different questions. MCP describes how one agent calls
a tool; ext-tool describes who is on the team. They compose, and both layers are
planned (#1354): a generic adapter that speaks MCP, so any existing server can
join as a member, and named adapters that use that transport while shipping
their own vocabulary and setup guide. Neither is implemented yet.

Where MCP is ahead today and ext-tool is not: a standard schema, discovery, and
a large body of existing servers. That is the reason to borrow the transport
rather than restate it.
