# Codex desktop app

This driver supports `where` only. Detection requires the exact environment value `CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop`, measured in a local desktop conversation shell on 2026-10-03. The app-server process itself carries `Codex`; ordinary terminal sessions did not carry the marker. Process ancestry is not inspected because the app sandbox denies `ps`, and ordinary terminal sessions also use helper binaries from the app bundle.

The placement ID is the caller-supplied thread ID, falling back to `CODEX_THREAD_ID`. Empty IDs and IDs containing tab, newline, or carriage return fail resolution. `CODEX_SESSION_ID` is not a fallback. An identified desktop host without a usable thread ID remains unresolved rather than inheriting a terminal pane.

`exclusive=1` prevents pane-environment fallback and stale pane-label lookup. `record_without_name=1` records the conversation placement without naming a pane, so team status identifies the desktop host. `where` reports `n/a:no_container_concept`; this host exposes no terminal window, tab, or split container.

Peek, poke, spawn, despawn, arrange, and name return `unsupported` (13) with a reason naming the Codex desktop app. Pane-state reports `unknown` / 13, never `gone`; there is no pane whose disappearance could justify deleting the conversation record. Activity, label, key, and title observations are `n/a:no_addressable_pane`.

## Delivery

With agmsgd enabled and running, notices arrive through the Codex queue using the thread and `codex_home` recorded by `actas`. The Codex app uses `~/.codex`. Delivery reaches idle desktop conversations; on macOS with agmsg 1.8.2, notices arrived 1–5 seconds after sending. The terminal driver supplies placement information; the agent type supplies the native delivery channel.

Run `$agmsg actas <name>` in each new chat to move delivery there. Until then it continues to the old chat. The new destination replaces the old record rather than failing as held. Monitor (legacy) and the shell shim apply to the terminal CLI, not this app.

The app shell has networking disabled by its sandbox. Local `send` and `inbox` work; remote sync and other network operations cannot run from that shell. Desktop delivery is verified on macOS. Identity, CLI session, and reach in team status are `n/a` because there is no addressable pane.
