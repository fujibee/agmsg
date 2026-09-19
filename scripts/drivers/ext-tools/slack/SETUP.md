# Slack ext-tool setup

Read this when `join <team> <name> ext-tool --tool slack` stops because no
member config exists yet. This is a guide for YOU (the seat LLM) to follow
while talking to the user — `setup` itself does not talk to anyone; you run
it, read its JSON, and decide what to say next.

**Do not hardcode any path in this file, including `~/.agents/skills/agmsg`.**
An install named anything other than `agmsg` (e.g. `agmsg-ext`) puts
everything under that other name instead. You are reading this exact file
from a real path already — it is `<skill-root>/scripts/drivers/ext-tools/slack/SETUP.md`
— so derive `<skill-root>` from wherever you actually found it. `<config_path>`
below is likewise whatever `join` told you it needs, in the message that sent
you here, never a path you compute from a guessed skill name.

Never ask the user to paste their bot token into the chat, and never run
`setup save` with a token value you were given directly. The token goes in
through `bash <skill-root>/scripts/ext-tool.sh secret <team> <name>` (not
`agmsg ext-tool secret` — there is no such command), which reads it without
echoing and writes it to a file only you get the *path* to — you only ever
handle that path.

## The five steps

1. **Create the Slack app from the manifest.**
   Tell the user to go to <https://api.slack.com/apps>, choose "Create New
   App" → "From an app manifest", pick their workspace, and paste the
   contents of `manifest.json` (next to this file). Confirm the app was
   created.

2. **Install it to the workspace.**
   In the app's "Install App" page, have them click "Install to Workspace"
   and approve the scopes. Slack then shows a **Bot User OAuth Token**
   starting with `xoxb-`.

3. **Save the bot token as a secret.**
   `secret` reads the token from a real terminal without echoing it, which
   needs a TTY this session does not have when it is running inside Claude
   Code's own `!` passthrough. Tell the user to open a separate terminal
   (not through you) and run:
   ```
   bash <skill-root>/scripts/ext-tool.sh secret <team> <name>
   ```
   and paste the `xoxb-…` token when prompted. This does not echo the token
   and does not go through you. It reports a file path back to the user —
   ask them for that path, and use it as `<key_file>` below. **Never accept
   a pasted token value here.**

4. **Verify the token, then pick and verify a channel.**
   ```
   <skill-root>/scripts/drivers/ext-tools/slack/setup check token <key_file>
   ```
   - `{"ok":true,...}` → token works, continue.
   - `{"ok":false,"error":"invalid_auth"}` → the token is wrong or was
     revoked. Have them re-check step 2/3 and re-save.
   - `{"ok":false,"error":"missing_scope"}` → the app's scopes don't match
     `manifest.json` (an app created by hand, or an older manifest). Have
     them add `chat:write` and `channels:read` under OAuth & Permissions,
     reinstall the app, and get a fresh token.

   Ask the user which channel to post to, **by channel ID, not name** —
   `check channel` calls Slack's `conversations.info`, which only accepts an
   ID (`C…`), never a `#name`. If the user gives a name, tell them how to get
   the ID: in Slack, click the channel name at the top of the channel → the
   panel that opens shows the Channel ID at the very bottom (or: right-click
   the channel in the sidebar → "View channel details" → same place). Then:
   ```
   <skill-root>/scripts/drivers/ext-tools/slack/setup check channel <key_file> <channel_id>
   ```
   - `{"ok":true,"exists":true,"bot_member":true}` → ready.
   - `{"ok":true,"exists":true,"bot_member":false}` → channel is real but the
     bot isn't in it. Tell the user to run `/invite @<the app's name>` in
     that channel (the name they gave the app in step 1), then check again.
   - `{"ok":false,"error":"channel_not_found"}` → the ID is wrong, or it's a
     private channel and the bot lacks `groups:read` (public channels only
     need `channels:read`) — add `groups:read` and reinstall if the target
     is private.

5. **Save, then send a real test message.**
   ```
   <skill-root>/scripts/drivers/ext-tools/slack/setup save <config_path> <key_file> <channel_id>
   <skill-root>/scripts/drivers/ext-tools/slack/setup test <config_path>
   ```
   `<config_path>` is whatever `join` told you it needs for this member — do
   not compute it from a guessed skill root; a differently-named install
   puts it somewhere else. `test` posts one real message
   ("agmsg: Slack setup test message.") and reports `{"ok":true}`,
   `{"ok":true,"permalink":"https://..."}`, or `{"ok":false,"error":"..."}`.
   When a `permalink` comes back, share that link with the user directly
   rather than asking "did it show up?" — it is only there for `setup test`;
   an ordinary send through `handle` stays silent on purpose (a reply would
   wake the sending seat again). No `permalink` field just means the link
   itself could not be fetched (e.g. a missing scope) even though the
   message did send — `"ok":true` on its own still means it worked, so ask
   the user to look for it in that case instead of treating this as a
   failure.

## Common failures, and what actually fixes them

| error | what it means | fix |
|---|---|---|
| `invalid_auth` | token is wrong, revoked, or from the wrong workspace | re-copy the token from step 2, re-save via `secret` |
| `not_in_channel` | bot has a valid token but isn't a member of the channel | `/invite @<bot>` in that channel |
| `channel_not_found` | channel ID is wrong, or it's private and the bot lacks `groups:read` | confirm the ID; add `groups:read` + reinstall for a private channel |
| `missing_scope` | the installed app doesn't have `chat:write` (or `channels:read` for `check channel`) | add the scope in OAuth & Permissions, reinstall, get a new token |
| `account_inactive` / `token_revoked` | the token was revoked (app uninstalled, token rotated) | reinstall the app, save the new token |
| rate limited (HTTP 429) | too many requests too fast | wait a few seconds and retry; not a configuration problem |
| a one-line message naming `curl`, a host, or a timeout | `handle`/`setup` couldn't reach the API at all (DNS, network, TLS) | check the machine's network; if `AGMSG_SLACK_API_BASE` is set in the real environment (it should only be set by the test suite), unset it — a value left over from testing silently redirects real messages nowhere |
