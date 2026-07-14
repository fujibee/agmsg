# Codex Native Scheduled Monitor

The native Scheduled monitor returns to one existing ChatGPT task and checks
agmsg metadata without a Desktop relay or background receiver.

It follows ChatGPT's documented scheduled-task model: a task scheduled from an
existing conversation returns to that conversation with its context, and local
project tasks require the ChatGPT desktop app and project directory to remain
available.

Official reference: [Scheduled tasks](https://learn.chatgpt.com/docs/automations.md)

## Cadence

- Start through 30 minutes: every 2 minutes.
- After 30 minutes through 4 hours: every 15 minutes.
- After 4 hours through 24 hours: every hour.
- At 24 hours: pause the same Scheduled task.
- On a newly observed unread message for the selected role: reset to every 2
  minutes and begin a new 24-hour cycle.

Empty, waiting, and not-due checks do not notify the user. The metadata check
does not read the message body or mark a message read. Only a wake result runs
the official `inbox.sh` command in the visible task.

## Start

From the Codex task that should receive the messages:

```text
$agmsg scheduled start <role>
```

The skill performs these steps:

1. Turns off hook and bridge delivery for the project.
2. Prepares one idempotent monitor state for the selected team and role.
3. Creates or updates one native ChatGPT heartbeat automation targeting the
   current task.
4. Starts it every two minutes in the local project directory.

The setup fails closed. If native Scheduled-task creation is unavailable, the
prepared state is stopped and agmsg does not report the monitor as active.

## Status and stop

```text
$agmsg scheduled status <role>
$agmsg scheduled stop <role>
```

`scheduled stop` invalidates the local state and pauses the native task. `mode
off` invalidates every Scheduled monitor state for the project. If direct pause
is temporarily unavailable, the next run receives `status=inactive` and pauses
itself.

## Safety boundaries

The Scheduled path never uses:

- Desktop relay or `CODEX_APP_SERVER_WS_URL`
- ChatGPT.app termination or restart
- launchd, cron, or a shell heartbeat
- a background receiver
- `codex exec resume`
- direct edits to ChatGPT automation files

The task runs unattended with the user's default Codex sandbox settings. The
agmsg `db`, `teams`, and `run` directories must remain writable; `install.sh`
adds those writable roots when Codex configuration is present.
