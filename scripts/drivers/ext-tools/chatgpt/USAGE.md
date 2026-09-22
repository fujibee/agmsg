# chatgpt — usage (for the seat sending to it)

## What it is

A ChatGPT conversation in an Orca built-in browser tab, joined as a team
member. Send it plain text — the message is typed into the composer and
sent; in the default `sync-wait` mode the reply arrives as this member's
agmsg reply once streaming finishes. Context is the conversation's own:
follow-up messages continue the same ChatGPT thread.

## What to send

Plain text, any shape — unlike `jev` there is no required JSON body. Keep
messages self-contained: ChatGPT sees only this conversation, not the
team's agmsg history, so include the context it needs.

## Timing

Replies are bounded by `timeout=300` (tool.conf). Ordinary questions land
in tens of seconds. If generation would exceed the budget the sender gets
`chatgpt: processing failed (reply did not complete before timeout)` —
the work is NOT lost, it is still in the ChatGPT thread, but this member
cannot relay it back. For deliberately long tasks ask the user's human to
switch the member to `mode=inject-only` and collect replies another way.

## Failure line vocabulary

- `no tab matching '<re>' in worktree <w>` — the tab was closed or navigated away
- `inject failed (composer-busy)` — an unsent human draft was in the way
- `send not confirmed in transcript` — the send rolled back; retry is safe
- `tab unrecoverable (health=..., reloads=N)` — page crashed repeatedly
- `another delivery is in flight` — serialized; a previous message is still being processed

## Optional: transcript watcher (async member)

`watch-transcript.sh <member.conf>` is a plain process (not an agent) that
polls the tab and posts completed assistant replies into the team through
send.sh under the member's own name. With `mode=inject-only`, `handle` no
longer injects at all: it appends the message to `<member.conf>.queue.d/`
and returns immediately -- agmsg already recorded the message, so there is
nothing to wait for and no timeout ceiling. The watcher drains the queue
only when the tab is HEALTHY_IDLE, one delivery in flight at a time:

    # usually automatic -- every delivery re-ensures it via the member's
    # handle, so a crash self-heals on the next message. Manual start:
    nohup bash watch-transcript.sh <member.conf> >/dev/null 2>&1 &

Recovery the watcher owns: retry-button clicks (up to 3), page-error and
repeated-UNKNOWN reloads, and frozen-generation reloads (transcript
unchanged ~90s while "generating"). A queued message that was injected and
confirmed but draws no reply within ~120s earns ONE reload; still nothing
after that and the original sender gets a `processing failed` notice.
Sending while ChatGPT is answering simply waits -- the queue preserves
order and each reply is routed to its own sender via the
`[agm <member>:<from>:<mid>]` marker.

A user message with no marker is a human typing straight into the tab --
when `human_relay_to=<member>` is configured it is relayed as
`boss -> <member>` and its reply goes to `<member>` too. Replies marked
for OTHER members sharing the tab are left to their own handle. First tick
is a baseline: nothing already in the transcript is replayed, except a
trailing reply to a marked delivery. One process per member config
(singleton via `<member.conf>.watchrun.lock.d`); `watch=no` in the config
disables auto-start.

Edge behavior observed in testing: concurrent sends are serialized by the
queue + tab lock; a reply pushed up the transcript by a later message is
still relayed; a reply stopped mid-stream ships with a
`[agmsg note: ...]` annotation when `judge_member` is set (replies under
~400 chars are not judged). State -- seen/announced sigs and the in-flight
delivery -- persists in `<member.conf>.watch.state` across restarts.

## Optional: judge_member

When the member config names a `jev` member of the same team, `handle`
asks jev to arbitrate exactly two ambiguous branches: whether an
UNKNOWN-state page should be reloaded now or given more time, and whether
a stable reply looks truncated mid-stream (a second opinion before
accepting it). Judging sends small page excerpts — the tab URL and up to
~1500 chars of reply tail — to jev's configured provider (OpenRouter or
TypeSafe). If the conversation content must not leave the machine, do not
set `judge_member`; the heuristics alone still work.
