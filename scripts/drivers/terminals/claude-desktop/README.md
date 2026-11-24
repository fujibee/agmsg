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

`terminal.conf` also carries two manifest-only flags `terminal-registry.sh`
reads by name, not by checking for `claude-desktop` specifically:

- `exclusive=1` — this driver can never be a NESTED terminal under another
  driver's pane the way herdr-in-tmux legitimately is. Without it, priority
  alone is not enough: a desktop session with no usable session id, with
  `TMUX`/`TMUX_PANE` inherited from an earlier terminal session in the same
  environment, resolved as a plain tmux pane instead of reporting its own
  unresolved id (reproduced). `exclusive=1` makes the resolver stop and fail
  loudly right there instead of falling through to the next candidate, and
  makes self-naming skip label-based pane lookup entirely once this driver
  is present — a stale `team:agent` label on some unrelated pane must not
  outrank it either.
- `record_without_name=1` — this driver has no `name` capability (there is
  no pane to rename), but still wants its placement recorded: without this,
  `agmsg_terminal_name_self` skips a no-`name` driver entirely, and
  `team.sh` would report the seat as `unknown:no_placement_record` rather
  than `claude-desktop`.

## where

The placement id is the Claude Code session id — the conversation itself is
the only handle a desktop seat has, there being no pane. The lookup order is
the caller's own argument first (the same value every other driver here is
handed), then `CLAUDE_CODE_SESSION_ID`, then `CLAUDE_CODE_HOST_SESSION_ID`.
**The last of those is the one that actually matters in practice**: measured
2026-10-02 on a live, desktop-spawned Claude Code process, the ordinary
`CLAUDE_CODE_SESSION_ID` a terminal session carries was absent there, while
`CLAUDE_CODE_HOST_SESSION_ID` (shape: `local_<uuid>`) held this process's own
identity.

`terminal_where` always answers `n/a:no_container_concept`: a desktop
session has no window, tab or split to report, and that is a decided fact
about this driver, not a failed read.

## pane_state

Always `unknown` / 13 — no addressable pane exists to ask about, ever. A
caller must never read this as `gone` and delete the placement record on it.

## Monitor / delivery

In the Claude desktop app's Code tab, an enabled and running agmsgd delivers through the Local session's cross-session socket, including while the conversation is idle. No Monitor is needed for that native channel; Monitor (legacy) remains an alternative when direct delivery is unavailable. On macOS with agmsg 1.8.2, notices arrived 1–5 seconds after sending.

Use a Local session and select the project folder for a lasting seat. Cloud sessions cannot reach this machine's install; without a selected folder, the app uses a scratch workspace. Run `/agmsg actas <name>` in each new chat to move delivery there; otherwise notices continue to the old chat. Handoff replaces the destination rather than failing as held. When a chat's process ends, delivery stops until another `actas`; queued messages remain and arrive afterwards.

Desktop delivery is verified on macOS. Identity, CLI session, and reach in team status are `n/a`, as in the Codex app; this is not an unverified pane identity.
