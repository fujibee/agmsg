# ADR 0008: Codex effective home and role-session ownership

**Status:** accepted
**Date:** 2026-09-20
**Deciders:** @fujibee

## Context

Codex Desktop/Orca can run with a state root different from `$HOME/.codex`. If
session discovery and role-session ownership use different roots, a bridge can
bind a role to another session's rollout or app-server.

## Decision

Codex state-root discovery uses one precedence order everywhere:

1. `AGMSG_CODEX_HOME`
2. `CODEX_HOME`
3. `$HOME/.codex`

Sessions are read from `<effective-home>/sessions`. Role-session records carry a
`codex_home=` field. Readers reject records owned by another effective home.
Legacy records with an empty field belong only to `$HOME/.codex`; they are not
reassigned to an isolated home. The production hook does not introduce a
`CODEX_SESSIONS` override.

## Consequences

The on-disk role-session record gains a field, so readers and writers must remain
backward compatible with records that predate `codex_home=`. An isolated Orca
home is explicit and cannot accidentally consume the default home's seat.
