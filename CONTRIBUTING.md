# Contributing to agmsg

Thanks for considering a contribution! agmsg is a small project; this guide is intentionally short.

## Where to start

- Read [`README.md`](README.md) for what agmsg does and how to install it.
- Read [`ARCHITECTURE.md`](ARCHITECTURE.md) for the mental model (3-axis driver, vocabulary, dependency-management philosophy).
- Browse [`docs/adr/`](docs/adr/) for the history of design decisions — they explain *why* things are the way they are.
- The [`docs/spec/`](docs/spec/) directory contains the formal contracts; consult these when implementing or extending a driver.

## Reporting bugs and requesting features

Open an issue on [`fujibee/agmsg`](https://github.com/fujibee/agmsg/issues). Include the agmsg version, the host agent (Claude Code / Codex / Gemini CLI / Antigravity), and a minimal reproduction if possible.

## Pull requests

1. Discuss substantial changes in an issue first.
2. Branch from `main`. Keep PRs focused — one logical change per PR.
3. Run the test suite: `bats tests/`.
4. Match the surrounding code style. Bash is the primary language; use `set -euo pipefail` at the top of every script.
5. Update docs if the change is user-visible.

## Releases

See [`RELEASING.md`](RELEASING.md). The short version: bump [`VERSION`](VERSION), run `./scripts/release/sync-version.sh`, commit, tag `v$(cat VERSION)`, push. CI handles the rest.

## Architecture Decision Records

agmsg uses ADRs ([Architecture Decision Records](https://adr.github.io/)) to capture significant design judgments. An ADR records the context, the decision, the alternatives considered, and the consequences.

### When to file an ADR

File a new ADR when proposing or accepting a change that:

- adds, removes, or replaces a driver axis,
- changes the driver interface or `AGMSG-DIRECTIVE` schema,
- changes how data is laid out on disk in a non-backward-compatible way,
- introduces a new external dependency (even an optional one),
- changes the project's vocabulary or naming conventions,
- or is otherwise a judgment call that future contributors will want to understand.

Small bug fixes, doc updates, dependency bumps, and new tests do not need ADRs.

### How to file an ADR

1. Copy [`docs/adr/template.md`](docs/adr/template.md) to `docs/adr/NNNN-short-title.md` where `NNNN` is the next free number.
2. Fill in the sections. Be honest in *Alternatives considered* — the value of an ADR is largely in capturing what you rejected and why.
3. Open a PR. Discussion happens on the PR. Status starts as `proposed`; mark it `accepted` when merged.
4. When a later ADR supersedes an earlier one, leave the original in place and link forward (`Status: superseded by ADR-XXXX`). ADRs are immutable history, not a wiki.

### When you find an undocumented decision

If you spot a design choice in the code whose rationale is unclear, an ADR retroactively capturing it is a welcome contribution. Mark it `accepted` and reference the commit or PR that originally introduced the behavior.

## Adding a driver

Bundled drivers live under `scripts/drivers/<axis>/<name>.sh`. (Top-level `.sh` files in `scripts/` are directly-invokable commands; subdirectories group implementation code.) Third-party plugin drivers live under `~/.agents/agmsg/plugins/<axis>/<name>/`. Both must implement the contract in [`docs/spec/driver-interface.md`](docs/spec/driver-interface.md).

A new bundled driver should arrive with:

- the driver script,
- bats tests under `tests/`,
- a README section or doc page describing the trade-offs of using it,
- and, if it changes the driver protocol itself, an ADR.

## Code of conduct

Be kind. Assume good faith. Disagreement on technical questions is welcome; disagreement on people is not.
