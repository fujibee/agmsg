# jev criteria wording — what was actually measured

Four real calls against OpenRouter's Jev decision endpoint, run by the
maintainer on 2026-09-20, changing only language or the `criteria` wording
of the `model` question (choices: `fable`/`opus`/`sonnet`/`haiku`). Relayed
here as reported — the exact `state` text used for each run was not
included in what reached this driver, so it is not reproduced below;
only the wording variant and its resulting number are.

## 1. Japanese `instructions`/`criteria`

Same question as run 2, written in Japanese instead of English.

Result: split — `sonnet` 0.50, `opus` 0.45. Ambiguous: the model could not
converge on one answer.

## 2. Same question, English `instructions`/`criteria`

Identical question to run 1, translated to English, wording otherwise
unchanged.

Result: `sonnet` 0.96 — converged on one clear answer.

## 3. Criteria wording that did not separate `opus`/`fable`

An earlier wording described `opus` and `fable` in terms of how much work
the task involved ("heavy"/complex vs. "light"/simple), without naming
what actually distinguishes them.

Result: `fable` 0.22 — buried under the other choices.

## 4. Criteria wording naming the actual decision boundary

Rewritten to name the real distinction: `opus` is "hard work whose scope is
already decided," `fable` is "long autonomous work with no settled scope."
Nothing else about the question changed.

Result: `fable` 1.00 — decisively selected.

## Takeaway

Language matters as much as content — write in English (runs 1 vs 2).
Vague criteria (heavy/light, hard/easy) collapse toward whichever choice
sounds most default; criteria that name the actual decision boundary
produce decisive, well-separated probabilities (runs 3 vs 4). See
`../USAGE.md` for how to apply this when writing a `questions` object.
