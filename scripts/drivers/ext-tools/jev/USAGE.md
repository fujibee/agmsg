# jev — usage (for the seat sending to it)

## What it does

Does not write prose, plans, or explanations. It answers one or more typed
questions about a `state`, each with a probability and a confidence — a
decision aid, not a chat partner. No memory across calls, no side effects.

**If you have more than one decision to make, ask them all in one call.**
Every question in `questions` comes back in the same response, keyed by
its own question name in `answers`. In that one measurement (below),
bundling 40 questions into one call was cheaper and barely slower than
asking one at a time, since `state` and every criterion's description are
paid for once in the request, not once per question (whether the endpoint
also answers them in parallel internally isn't something this has
measured — TypeSafe's own docs describe it that way, see below). TypeSafe
calls this **speculative fan-out**: include questions you're not even
sure are relevant, and let your own code decide afterward which answers
to use (<https://docs.typesafe.ai/patterns/fan-out.md>, which also
describes the questions as evaluated in parallel).

Measured once (2026-09-21, via OpenRouter) — not a guaranteed number:

| questions in one call | latency | cost |
|---|---|---|
| 1 | 0.333s | $0.000021 |
| 40 | 0.461s | $0.000460 |
| 40, sent one at a time instead | ~12s | ~$0.00084 |

**The real ceiling on a batch is total input tokens, not how many questions
or lines you send** (measured 2026-09-24). Time is not a concern either
way — even the slowest successful call measured was 2.42s, well under this
member's 10s timeout. `state` plus every question's
own `criteria` descriptions all count toward the same per-call input total,
and `criteria` is repeated in full for EVERY question that uses it — so how
many questions fit in one call depends heavily on how many choices each one
has, not just their count:

- A 2-choice question (e.g. yes/no): 100+ in one call, comfortably.
- A 77-choice question: about 40 in one call — the same request shape hit
  the limit at 46.

Sending too much in one call does not hang or get billed: the provider
rejects it immediately with HTTP 400 (`max_tokens_exceeded`), and this
member reports that as one line — `jev: request too large for one call
(max_tokens_exceeded) -- split the questions into smaller batches` — costing
nothing. If you hit it, split the batch and send the remainder as a further
call.

## How to send it

Send through `send.sh`, addressed to this member — one message, not by
calling `handle` directly as a subprocess. `handle` is the entry point
*agmsg itself* invokes when a message actually arrives; calling it
directly still gets a real answer (it has no way to tell it's being run
outside agmsg), but two things don't happen: neither the request nor the
reply lands in the team's history, and `tool.conf`'s timeout is never
enforced (that's the dispatcher's job, not `handle`'s).

There's a real reason this is tempting: agmsg has no synchronous way yet
to get the answer back inside the same script that sent it — a reply
arrives later, as its own message, which a script can't collect in place.
That gap is real and already documented elsewhere as something not built
yet; it's not this driver pretending the problem doesn't exist. But
routing around it with a direct `handle` call is what loses the record
above — the decision still happens, it just never shows up anywhere a
seat looking at the team's history would find it.

## What to send

Body must be JSON with `state` and `questions`. Anything else — plain
text, JSON without a `questions` key — is refused. `criteria` is an
OBJECT (choice → description), never an array (an array is rejected
outright: `expected record, received array`).

The example below bundles two related questions (which model, how much
effort) into one call — the same shape works for many unrelated questions
in a single call too, per the fan-out note above.

```json
{
  "state": "Fix a flaky CI job that intermittently times out on macOS runners.",
  "questions": {
    "model": {
      "type": "choice",
      "instructions": "Pick the Claude model to route this coding task to.",
      "criteria": {
        "haiku": "fastest and cheapest; trivial, fully specified edits",
        "sonnet": "ordinary implementation work with some investigation",
        "opus": "hard work whose scope is already decided: a known fix or a specified change, however intricate",
        "fable": "long autonomous work with no settled scope: the model must make the design decisions itself, including one-way choices it cannot take back, and keep going for hours without a human in the loop"
      }
    },
    "effort": {
      "type": "choice",
      "instructions": "Pick the reasoning effort for this task.",
      "criteria": {"low": "mechanical, no investigation", "medium": "some reasoning and reading", "high": "deep investigation across files"}
    }
  }
}
```

With exactly one question, the reply is one line (no name prefix, since
there's nothing to disambiguate):

`jev: sonnet (choice p=0.72, confidence=0.61, cost $0.000016)`

**With two or more questions (like the example above), the reply is one
LINE PER QUESTION** — `name=choice (p=…, confidence=…)`, addressable by its
own question name rather than by position, since position silently breaks
if the endpoint (or a future request) ever reorders answers. The call's own
aggregate cost is appended to the LAST line, since it describes the whole
call, not any single question:

```
jev: model=sonnet (p=0.72, confidence=0.61)
effort=high (p=0.85, confidence=0.79) (cost $0.000016)
```

If one question's own answer comes back malformed (missing a choice, or a
choice absent from its own probabilities), that question alone renders as
`name=error (malformed answer)` on its own line — every other question's
real answer still comes back. This only applies with 2+ questions; with
exactly one, a malformed answer fails the whole call the same as any other
unexpected response shape (there is nothing else in the reply to salvage
it with).

This member may be connected through OpenRouter or TypeSafe's own native
API (a setup-time choice, invisible to what you send — the request/reply
shape is identical either way except for one thing): TypeSafe's real
response carries no cost figure at all, so a member connected that way
ends its reply with `tokens 296 in / 20 out` instead of a `cost` — never a
self-calculated dollar estimate standing in for one it never measured.

## When it refuses, and before acting on an answer

A refused call is always one fixed line: no key configured, an invalid
key, rate limiting, a network failure, an unexpected response shape, a
body not shaped as above, or the batch was too large for one call (see
above — split it and send the remainder separately). Separately: check
confidence PER QUESTION, not once for the whole reply — with several
questions in one call, each one's own confidence can differ. If a given
question's confidence is below 0.5–0.7, do not act on that answer
automatically — hand that one decision to a human or an ordinary model
instead.

## Tips for asking well

Measured today (numbers in `USAGE/criteria.md`):

- Write `instructions`/`criteria` in **English**. The same question in
  Japanese split the model choice (sonnet 0.50 / opus 0.45); in English it
  converged (0.96).
- Write each criterion so the **boundary** is unambiguous. "heavy" vs
  "light" is vague; naming whether the scope is already decided or not is
  not — that rewrite alone took one model's probability from 0.22 to 1.00
  on the same task.
- Write `state` concretely: name the actual files/symptoms/task, not a
  category.
