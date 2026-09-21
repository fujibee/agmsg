# jev — usage (for the seat sending to it)

## What it does

Does not write prose, plans, or explanations. It answers one or more typed
questions about a `state` you give it, each with a probability and a
confidence — a decision aid, not a chat partner. One call is fast (0.2–0.3s)
and cheap (about $0.00002 per call). No memory across calls, no side effects.

## What to send

Body must be JSON with `state` and `questions`. Anything else — plain
text, JSON without a `questions` key — is refused. `criteria` is an
OBJECT (choice → description), never an array (an array is rejected
outright: `expected record, received array`).

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

The reply is one line: `jev: sonnet / high (choice p=0.72, confidence=0.61, cost $0.000016)`

This member may be connected through OpenRouter or TypeSafe's own native
API (a setup-time choice, invisible to what you send — the request/reply
shape is identical either way except for one thing): TypeSafe's real
response carries no cost figure at all, so a member connected that way
ends its reply with `tokens 296 in / 20 out` instead of a `cost` — never a
self-calculated dollar estimate standing in for one it never measured.

## When it refuses, and before acting on an answer

Refusal is always one fixed line: no key configured, an invalid key, rate
limiting, a network failure, an unexpected response shape, or a body not
shaped as above. Separately: if confidence is below 0.5–0.7, do not act on
the answer automatically — hand the decision to a human or an ordinary
model instead.

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
