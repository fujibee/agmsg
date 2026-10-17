# agmsgd — architecture design

This is the architecture design for agmsgd: the approved direction in [the RFC](agmsgd-rfc.md), worked down to how each part behaves. It describes the current design only; the reasoning behind each choice lives in the discussion and in the ADRs that will follow. Implementation has not started. The technical design (where the source lives, how it is built and shipped, the main components) comes next.

**1.6.0 beta scope:** the optional, default-off daemon queues inbox notices for Codex sessions against the existing SQLite store, before the 2.0.0 migration. Existing bridges and remote sync processes remain separate; a live bridge continues until its Codex session restarts. `agmsg daemon enable` changes new Codex launches, while `agmsg daemon disable` lists sessions that need restarting to restore bridge notices. If `agmsg` is not found, use `<install>/scripts/agmsg daemon enable|disable`. macOS and Linux are supported. Windows delivery remains unsupported pending measurement, and JSONL storage is unsupported. The beta does not implement the 2.0.0 storage or delivery changes described below.

Status: 2026-09-28. [日本語版](agmsgd-architecture.ja.md)

## 1. Overview

agmsg lets the agents of one team (Claude Code, Codex and others) message each other. agmsgd is a daemon that runs once per install. It notifies sessions even while they are idle, and it owns sync, external-tool (ext-tool) runs and the hand-off of despawn requests. Alongside the daemon, messages gain a shared id, a subject and a summary; each identity can be held by at most one session within an install; and the store switches to one row per recipient.

The daemon is optional. Without it, today's usage (bash and sqlite only) keeps working. Users and agents only ever type the `agmsg` command.

## 2. Overall structure

```mermaid
flowchart LR
  subgraph install["one install (one agmsg installation on a machine)"]
    cc["Claude Code session<br/>pane / stream / thin watcher"]
    cx["Codex and other sessions<br/>pane / hook"]
    cli["agmsg command (bash)"]
    d["agmsgd<br/>one per install, optional<br/>delivery loop, sync, ext-tool runs, despawn"]
    rec[("install record<br/>sessions, noticed, reservations, ledger")]
    ts[("team store<br/>per team, source of truth for messages")]
    ext["external tool"]
  end
  srv["sync server<br/>(other machines)"]
  d -->|notify| cc
  d -->|notify| cx
  cli -->|send / read, with or without the daemon| ts
  d --- rec
  d --- ts
  d -.->|starts| ext
  d -->|sync (content only)| srv
```

When the daemon is not running, Claude Code receives through a thin watcher and Codex through its hook.

There are two stores:

- **The team store** (one per team) is the source of truth for messages and read state. Sync keeps its content equal across machines.
- **The install record** (one per install, `run/install.db`) holds this machine's sessions, what has been noticed, in-flight reservations, the external-tool ledger and records of anything that stopped. It is never synced.

Sending, reading, history and search go straight to the stores through the `agmsg` command (bash and sqlite). They do not pass through the daemon. The daemon handles delivery (notifications), sync, starting external tools and handing over despawn requests. Sessions talk to it over a socket inside the install.

## 3. Components

### 3.1 Message shape

- The sender assigns a shared id (uuid7) when the message is created. The same message arriving through a different server stays one message, and moving to another server does not change the id.
- The sender may add a subject (up to 200 characters) and a summary (up to 1000 characters). These limits will not be raised later; anything longer is refused at send time. A message without a subject uses the first line of its body in the notification line. The summary is not shown in notifications; it is for sync and search.
- The values set at creation (sender, recipient, id, subject, summary) are never rewritten. A rename only changes what is displayed when reading.
- Older versions (1.3.1 and later) skip fields they do not know and still receive the message.

### 3.2 Storage

- The team store's source of truth is an append-only event log. A message is kept as one row per recipient and grouped back into one message by its shared id when read. The inbox counts per recipient; history counts per message.
- A message to a tag (every member subscribed to it) has its recipients fixed at send time and becomes one row per recipient. Subscribing and unsubscribing are recorded as events too, and are folded in order.
- Read state is synced and is the same on every machine. "Noticed" is per machine and lives in the install record.
- Search is plain substring matching, with no index. Neither history nor search changes read state, even when they show the body.
- The storage backend is sqlite only.

### 3.3 Identity and holding a name

- An identity is a name within a team plus a member id that never changes. Names are reserved: leaving does not free the name.
- Within one install, at most one session can hold a given identity. The record of who holds what (claims) lives in the install record and, once the groundwork is activated, it is the only source of truth. Every time a session takes the name, its generation and token change.
- Sending and marking read are accepted only when they carry the current holder's token. A trigger inside the team store checks this: a send from older code that does not know the token is refused, and a read from older code is silently dropped (the message stays unread and the new watcher delivers it).
- Handing a name to another session, or giving it back, goes in three steps. If it stops half way, the next command or the daemon that touches it completes it.
- A refused send says one of four things: a hand-over is in progress (wait and retry) / the name moved to another session / waiting for recovery / this process is older than the installed agmsg ("agmsg was updated while this process was running…").
- A session without an identity can neither receive nor send.
- Holding the same identity from another install or another machine is not prevented; it only shows up in diagnostics.

### 3.4 Delivery: choosing the channel, and the notice tag

- Each registration has exactly one channel. If its pane is known for certain, the notice goes to the pane. If it certainly has no pane, the channel of its type is used (stream for Claude Code, hook for Codex). If it cannot be determined, nothing is written anywhere, delivery stops, and the reason shows in the status view. This avoids falling back to a lower channel and writing into someone else's session.
- What gets delivered is "unread and not yet noticed" (for hooks: "unread"). A notice does not mark anything read. A message becomes read only when `inbox` or a hook hands over its body.
- Notices are at-least-once: the same notice can appear twice. That never affects read state.
- Each session has at most one delivery reservation in flight. The target is checked again right before writing. While an external child process is still running for that session, nothing more is sent.
- Pane notices use a tag: `<agmsg-notice from="alice" unread="3">subject</agmsg-notice>`, at most 200 characters on one line. `<`, `>`, `"` and `&` inside the subject are neutralised, so the subject cannot escape the tag. Anyone can type this shape, though, so it does not prove who sent it (the skill text says so as well).
- Control characters written to a pane are replaced with visible ones (ESC becomes `␛`, a newline `↵`, a tab a space, and so on), so they never act as terminal control or key input. `poke` follows the same rule, and ships it first, from 1.4.2 on.
- No new verbs are added to terminal drivers (tmux, herdr, Orca and so on). The contract with a driver is that text is sent as literal text.

```mermaid
sequenceDiagram
  participant A as sender (alice)
  participant S as team store
  participant D as agmsgd
  participant B as recipient (bob)
  A->>S: 1. agmsg send (with id and subject); token checked, one row per recipient appended
  D->>S: 2. find unread and not yet noticed
  Note over D: take the session's reservation, choose the channel, check again right before writing
  D->>B: 3. notice <agmsg-notice…> via exactly one of pane / stream / hook
  D->>D: 4. record "noticed" in the install record
  B->>S: 5. agmsg inbox reads the body, which marks it read (token checked)
  Note over S: read state reaches other machines through sync. A hook does 3 to 5 in one call.
```

### 3.5 The daemon (agmsgd and the agmsg command)

- The process is named `agmsgd`, one per install. Its owner record lives in the install record and its generation goes up on every start. A second start exits with a reason while the current owner is alive.
- Users and agents type only `agmsg`: `agmsg daemon start` / `stop` / `status`. `agmsgd` is a small executable that serves as the Node entry point, and it is the only part that needs Node 22.13.0 or later. `agmsg` itself runs on bash and sqlite.
- When the install is updated, the daemon steps aside by itself. A new version never stops an old one with a signal; signals are sent only where that is safe (Linux pidfd).
- A team store belongs only to the install that took it over. A store copied from another install is taken over only through an explicit command (`agmsg daemon adopt-store`), and only from a fresh, consistent copy.
- Whether the daemon is meant to run is recorded, so "deliberately not used" and "failed to start" can be told apart.

### 3.6 Sessions and the daemon

- A session connects to the daemon through a socket inside the install (a different name for each daemon generation) and registers itself. The daemon checks the registered session's token before sending it a notice.
- The daemon never sends messages on anyone's behalf. Sending is always the session's own `agmsg`.
- Stream (Claude Code): the daemon sends the notice, and the client replies "delivered" once it has written it to its output. If the connection drops, the reservation survives, and the same client can reconnect and report the result.
- Hook (Codex and others): on each turn the hook asks the daemon, receives the unread bodies, hands them over and marks them read. One turn's delivery is a single operation, so a crash in the middle neither duplicates nor loses anything.
- For a pane-only session, the hook is not given the bodies (the daemon writes to the pane instead).
- If the daemon is stopped, Claude Code stream sessions move to the thin watcher from their next session start. Nothing unread is lost.

### 3.7 Sync

- Only message content is synced, read state included. "Noticed", sessions and delivery records stay on their machine.
- Each team has exactly one sync owner. Moving it from today's sync process (the engine) to the daemon happens only through an explicit command (`agmsg sync adopt`). The daemon does not start syncing until the old engine process is known to have ended, so two processes never sync at once. `agmsg sync handoff` moves it back.
- Sync can be turned off on purpose, and that record wins over requests that arrive later.
- Rows that are still encrypted with an old key and were never taken in cannot be recovered once that key is gone. They are counted and shown.

### 3.8 External tools (ext-tool)

- An external program can be called as a team member. The contract with the adapter (JSON on stdin, the reply on stdout, the exit code, the time limit) does not change.
- There is one ledger row per message. "About to start" is recorded before the child is created, so a message without a ledger row has certainly never been started. All results are saved before the reply is sent.
- A run whose outcome is unknown (it crashed after starting) is never started again. Messages to the same member are started one at a time, in arrival order.
- Ownership of running external tools moves to the daemon automatically the first time it starts under 2.0.0. Messages that arrived before the store switch are not run again, because whether they already ran cannot be known (they are counted). Messages that arrived after the switch and have not run on this install are run once ownership has moved, however long ago they arrived.

### 3.9 despawn

- The side that asked closes the pane itself, after confirming that the target session gave its name back.
- Asking sends a clean-up request (message kind `ctrl.despawn`). Message bodies are never executed as commands. Only requests recorded as accepted on this install are executed; requests that arrive through sync or a copy are not.
- The receiver sits inside the target session: the stream client or hook when the daemon runs, the thin watcher or hook when it does not. The receiver checks that the request is addressed to its own session, then gives the name back. A session with no receiver (pane-only, no hook) can only be removed with `--force`.
- Before closing, it checks that the terminal server is the same one as when the request was made, and that the session that gave the name back is still in front in that pane. If this cannot be confirmed, the pane is not closed (the name is still given back). Closing is attempted once; if the result is unknown, it is not retried. The report keeps "gave the name back" and "closed / did not close the pane" apart.
- Requests expire, and expired requests are not executed. The daemon never forces.
- Accepted gap: if the pane's contents change to another session between the check and the close, that session is closed. This includes a successor session starting in the same pane, and it can happen under tmux too. Today's code has the same window ([#1385](https://github.com/fujibee/agmsg/issues/1385)).

### 3.10 Seeing what is going on

- `agmsg doctor` (today's `doctor.sh`) gains sections for eight things that must be visible: sessions and channels / recent deliveries / sync / reasons something stopped / despawn requests / external-tool results / versions / each session's receiving state. `agmsg daemon status` shows the daemon's share of these.
- It only reads. It never rewrites records and never triggers recovery. It asks the daemon only about connections that are live right now.
- Wording that keeps failures from going silent: never report "0" for something that could not be read / without a stop record, say "no recorded stop", not "not stopped" / say alive, dead or cannot tell / attach the time of each observation.
- When the daemon cannot be reached, the first line says so, and each section says it was read from records. A setup that deliberately does not use the daemon is not reported as a fault.

## 4. Migration and release order

### Approach

- Everything that is not backward compatible ships once, in 2.0.0: the data-shape switch, the receiving format (delivery by the daemon, and how noticed and read are kept apart), sync moving into the daemon, and the join / drop / leave vocabulary.
- Everything else goes into 1.x wherever possible, so problems surface early.
- 2.0.0 ships together with delivery by the daemon (notices into idle sessions). Before it, 2.0.0 release candidates are cut and checked on real machines.
- Nothing is double-written ("shadow-written") to new tables during 1.x. Older versions and rows arriving through sync would not write the shadow, so the switch would have to copy from today's tables anyway.

### The migration check (during 1.x)

- `agmsg migrate --check` takes a consistent copy of the real store and runs the same switch code as 2.0.0 on that copy, all the way through. The real store is not changed. It can be run any number of times.
- It reports: lost and duplicated messages, whether content matches, read counts, overlaps in the identity fold, rows it cannot take in, rows that do not fit the new shape's constraints, and time taken.
- The identity fold (2.0.0 folds identity to "team and name"):
  - **Conflicts that stop the switch:** the same name with different ids (including ids assigned differently on different machines), and the same name with two live owners (including when that cannot be determined). The switch does not proceed until the user chooses. The check then reports "waiting for a choice", never "passed".
  - **Shown only as notes:** the same name on different types (Claude Code's `bob` and Codex's `bob`), and the same name and type in different projects. Several registrations under one identity are not a conflict; all of them stay. Under 2.0.0, as today, only one session can hold the name at a time.
- The check writes only to the copy, in a place it created itself, and never runs sync, notices, pane closing or external tools. In 1.x, no ordinary command can reach the switch code.
- What it can promise is only this: with the same input, the same version and the same choices, the 2.0.0 switch gives the same result as the check. The real store keeps changing, so the check is run again right before the real switch.
- Warning at join: if the same name already exists on another type or in another place, join says "under 2.0.0 this is treated as the same identity, and only one session can hold it at a time". Join does not refuse.

### The switch to the new store (2.0.0)

- The switch happens in place, in the same file. Before it, a consistent copy (backup) is taken and its location is shown.
- If a conflict that stops the switch remains (the same name with different ids, or two live owners), the switch waits until the user chooses.
- Raising the writer's generation mark is the point of no return. From then on, code from before the switch can no longer send, take in rows or sync. An old sync engine is refused by the version gate.
- Messages that were unread before the switch are announced in one line: "N unread from before the migration".
- If a store from an older version is restored from a copy, the install notices it through the lowest generation it remembers.
- The daemon starts only on an install whose switch is complete, and serves only switched stores.

### Release order

```mermaid
flowchart LR
  p0["earlier (1.4.0 on)<br/>ext-tool v1, Orca, poke"] --> p2["1.x<br/>shared id, subject, summary"]
  p2 --> p3["1.x groundwork<br/>holding names, send gate, despawn,<br/>migration check"]
  p3 --> p4["2.0.0 (rc first)<br/>switch, daemon, receiving format,<br/>sync in the daemon, join/drop/leave"]
  p3 -.->|deactivate the groundwork, go back (before the switch only)| p2
  p4 -.->|stop the daemon, stay on 2.0.0| p4
```

The only step that cannot be undone is the 2.0.0 switch.

| release | what goes in | what can be stopped (and how) | what cannot be undone |
|---|---|---|---|
| earlier (1.4.0 on) | ext-tool v1, the Orca terminal driver, and from 1.4.2 on the replacement of control characters in `poke` and pane text | `poke` can go back to an earlier version | nothing |
| 1.x | shared id, subject and summary; a wider re-read of rows set aside earlier; the notice line format | stop sending the new fields (receiving continues) | nothing (fields are only added; the re-read is idempotent) |
| 1.x groundwork | the install record, holding names and activating it, the send and read gate, the refusal messages, recovery of a stopped hand-over, despawn requests and their receiver, the groundwork section of `agmsg doctor`, the deactivate command, the migration check, the warning at join. Search (substring) may also come here | `agmsg deactivate` returns to the pre-activation state, and an earlier version can be installed again (before the switch only; no data is lost; while deactivated the groundwork's protection does not apply). The migration check runs only on a copy | nothing |
| 2.0.0 (after release candidates) | the data-shape switch (one row per recipient, tag addressing and subscriptions, the switch command), the receiving format (delivery by agmsgd, the noticed record and "read only what was shown", hook read state), sync inside the daemon, the join / drop / leave vocabulary, external-tool delivery, despawn through the daemon, the daemon section of `agmsg doctor` | before the switch: simply do not switch. After it: stop the daemon and continue on 2.0.0 without it (send, read and search; the thin watcher and hooks; sync handed back to today's engine with `handoff`; external-tool messages are kept until the daemon is back) | the data-shape switch (only restoring a backup reverses it); folding registrations under one name (the user chooses); side effects already done, such as external tools that ran or panes that were closed |

Search works on today's tables, so it can come forward into 1.x or stay in 2.0.0; the promise is the same either way. That is decided when implementation starts.

To check in 2.0.0 release candidates: the switch on a copy of a real store (matching the migration check), daemon delivery to real sessions, `sync adopt` and `handoff`, the external-tool migration, continuing with the daemon stopped, and despawn.

## 5. Properties kept, and their limits

| property | limit (what is not promised, and under which conditions) |
|---|---|
| No message is lost at any point in the release order | Rows still encrypted with an old key and never taken in do not come back if that key is lost. Restoring a backup loses the changes made after it |
| An older version (1.3.1 or later) still running does not stop anything | The older version simply does not see new things (tag addressing and so on). After the switch, an older version cannot send on that install |
| Within an install, at most one session holds an identity | Overlap with another install or another machine is not prevented (diagnostics only) |
| Sends and reads are accepted only with the current holder's token | Not while the groundwork is deactivated |
| A session never has two channels chosen at once | Duplicates after a crash are within at-least-once |
| Notices arrive (at-least-once) | The same notice can appear twice. Writing to a pane is no proof the model saw it. Only for the supported types and channels (the Codex desktop app is outside v1) |
| A notice does not mark anything read | — |
| Text written to a pane never acts as terminal control or key input | This is kept at the level of form only. It cannot stop a subject from posing as an instruction inside the tag, or a model from following it. The tag does not prove the sender |
| An external tool is never started twice for the same message | Right after an upgrade, while untraceable runs from the older version remain, it may run in parallel with another message to the same member (no upper bound on that period is promised). Messages that arrived before the switch are not run |
| despawn never removes a new session with an old request, and the daemon never forces | The window where the pane's contents change between the check and the close (#1385). Expiry is judged when observed, so a request can run slightly after it expires |
| Nothing stops silently | A crash before the preparation record is written cannot be observed |
| There is exactly one irreversible switch, announced in advance | Side effects already done cannot be undone |
| Today's usage keeps working without the daemon (also when the daemon is stopped under 2.0.0) | Without the daemon there are no pane notices, no sync inside the daemon and no automatic external-tool runs. A session with no receiver can only be despawned with `--force` |

## 6. Not yet measured, and to confirm during implementation

### Still unmeasured

- Whether a herdr driver can read a value that identifies the server instance (to tell restarts apart). Until it can, despawn does not close panes under herdr (the name is still given back). Also, whether pane numbers are reused across a server restart.
- How far a driver can find the foreground process of a pane under tmux.
- Which earlier versions can be returned to after deactivating the groundwork (from which version the lock keys and owner-token rules are the same as today).
- Where Windows cannot confirm whether a process is alive or which process group it belongs to (reported as "not supported").

### To confirm during implementation

- Behavior when something crashes half way, checked by fault injection: hand-overs, each step of activation and deactivation, each step of the switch, each step of starting an external tool, closing a pane in despawn, and permission and disappearance of the child that writes the lock.
- `agmsg doctor` finishes within 5 seconds, and none of its functions write anything.
- Terminal drivers send text as literal text (a conformance test; the Orca driver must pass it too before use).
- Replacing characters in notices leaves no control characters, keeps Japanese and emoji, and nothing downstream interprets backslashes.
- A change that affects how sessions coexist is accompanied by a run with two real sessions (process counts per role and so on).

### Measured and settled

- From Node 22.13.0, Node's built-in SQLite works without a flag and has the operations needed. Full-text search (FTS5) is not included.
- The sync engine runs at most once per team on the measured machine, and its pidfile often disagrees with the real process (the reason the pidfile is not treated as the truth).
- herdr does not reuse pane numbers while the same server is running, and the foreground process of a pane can be read.

## 7. Terms

| term | meaning |
|---|---|
| install | one agmsg installation on a machine. The daemon and name exclusivity are both per install |
| identity | a name within a team plus a member id that never changes. Names are not freed |
| hold (a name) | a session taking on an identity and starting to use it (today's `actas`). Only one per install |
| session's hold | the state of holding a name. It has a generation and a token, both of which change on every hand-over |
| team store | the per-team store. Source of truth for messages and read state. Sync keeps its content equal across machines |
| install record | the per-install store (`run/install.db`): holds, noticed, reservations, ledger. Not synced |
| noticed | the record that this machine showed a notice. Separate from read |
| switch | the switch to the new store (2.0.0). The only point of no return |
| migration check | `agmsg migrate --check`. Runs the same switch as 2.0.0 on a copy of the real store and compares. Can be run any number of times during 1.x |
| rc | a release candidate cut before 2.0.0 (`2.0.0-rc.N`), to check on real machines |
| groundwork / activate / deactivate | the release that turns on name holding and the send gate. Activating turns it on; deactivating returns to the earlier state |
| channel | how a notice travels: pane, stream (Claude Code) or hook (Codex and others) |
| thin watcher | how Claude Code receives when there is no daemon (the successor of today's `watch.sh`) |
| tag addressing / subscription | sending to every member subscribed to a tag. Recipients are fixed at send time |
| ext-tool | the mechanism that makes an external program a team member. One ledger row per message |
| at-least-once | delivered at least once; may appear twice |
