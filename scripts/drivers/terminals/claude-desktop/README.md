This driver's own capability notes (#1082) — read only after `where.sh` names
this session's terminal as `claude-desktop`. Its manifest ceiling
(`terminal.conf`): `where` only. Every other verb — peek, poke, spawn,
despawn, arrange, name — is not in that ceiling and reports `unsupported`
(13) if called anyway, naming the Claude desktop app as the reason: it has no
addressable pane for any of them to act on.

Detection is env-only: `CLAUDE_CODE_ENTRYPOINT=claude-desktop` (measured
2026-10-02 on a live desktop app process; a plain terminal session carries
`CLAUDE_CODE_ENTRYPOINT=cli`). Priority is above herdr and orca, so the
entrypoint marker wins even if a pane env var leaked in from somewhere else
(e.g. an earlier terminal session's placement left in the environment).

## where

The placement id is the Claude Code session id — the conversation itself is
the only handle a desktop seat has, there being no pane. **The id comes from
`CLAUDE_CODE_HOST_SESSION_ID`, not `CLAUDE_CODE_SESSION_ID`**: measured
2026-10-02 on a live, desktop-spawned Claude Code process, the ordinary
`CLAUDE_CODE_SESSION_ID` a terminal session carries was absent there, while
`CLAUDE_CODE_HOST_SESSION_ID` (shape: `local_<uuid>`) held this process's own
identity. Both are tried, in that order, before falling back to the caller's
own argument being empty altogether.

`terminal_where` always answers `n/a:no_container_concept`: a desktop
session has no window, tab or split to report, and that is a decided fact
about this driver, not a failed read.

## pane_state

Always `unknown` / 13 — no addressable pane exists to ask about, ever. A
caller must never read this as `gone` and delete the placement record on it.

## Monitor / delivery

Unchanged by this driver. Receiving agmsg messages in the desktop app's Code
tab still goes through the same Monitor mechanism every other Claude Code
seat uses.
