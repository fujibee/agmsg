# Slack ext-tool setup

Read this when `join <team> <name> ext-tool --tool slack` stops because no
member config exists yet. This is a guide for YOU (the seat LLM) to follow
while talking to the user — `setup` itself does not talk to anyone; you run
it, read its JSON, and decide what to say next.

Never ask the user to paste their bot token into the chat, and never run
`setup save` with a token value you were given directly. The token goes in
through `agmsg ext-tool secret`, which reads it without echoing and writes it
to a file only you get the *path* to — you only ever handle that path.

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
   Tell the user to run, in their own terminal (not through you):
   ```
   agmsg ext-tool secret <team> <name>
   ```
   and paste the `xoxb-…` token when prompted. This does not echo the token
   and does not go through you. It reports a file path back to the user —
   ask them for that path (or read it from wherever `join`/`secret` recorded
   it for this member, once that plumbing exists), and use it as
   `<key_file>` below. **Never accept a pasted token value here.**

4. **Verify the token, then pick and verify a channel.**
   ```
   scripts/drivers/ext-tools/slack/setup check token <key_file>
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
   scripts/drivers/ext-tools/slack/setup check channel <key_file> <channel_id>
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
   scripts/drivers/ext-tools/slack/setup save <config_path> <key_file> <channel_id>
   scripts/drivers/ext-tools/slack/setup test <config_path>
   ```
   `<config_path>` is `~/.agents/skills/agmsg/ext-tools/<team>/<name>.conf`.
   `test` posts one real message ("agmsg: Slack setup test message.") and
   reports `{"ok":true}` or `{"ok":false,"error":"..."}`. Confirm with the
   user that it actually showed up in the channel before calling this done —
   a `true` from Slack's API is not the same as a human having seen it.

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
