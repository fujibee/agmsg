# Jev ext-tool setup

Read this when `join <team> <name> ext-tool --tool jev` stops because no
member config exists yet. This is a guide for YOU (the seat LLM) to follow
while talking to the user — `setup` itself does not talk to anyone; you run
it, read its JSON, and decide what to say next.

**Do not hardcode any path in this file, including `~/.agents/skills/agmsg`.**
An install named anything other than `agmsg` (e.g. `agmsg-ext`) puts
everything under that other name instead. You are reading this exact file
from a real path already — it is
`<skill-root>/scripts/drivers/ext-tools/jev/SETUP.md` — so derive
`<skill-root>` from wherever you actually found it. `ext-tool.sh` below
(also under `<skill-root>/scripts/`) resolves and passes the member config
path itself for every command that needs one; you never compute or type
that path.

Never ask the user to paste their OpenRouter API key into the chat, and
never run `ext-tool.sh setup ... save` with a key value you were given
directly. The key goes in through `ext-tool.sh secret` (there is no `agmsg
ext-tool secret` command), which reads it without echoing and writes it to a
file only you get the *path* to — you only ever handle that path.

## The three steps

1. **Get an OpenRouter API key.**
   Tell the user to go to <https://openrouter.ai/keys> (if they don't
   already have a key) and create one. A conventional place to keep it is
   `~/.config/openrouter/key`, but any path they choose is fine — `setup`
   never assumes a fixed location.

2. **Save the key as a secret.**
   Ask the user to copy the key to their system clipboard, then run this
   YOURSELF:
   ```
   bash <skill-root>/scripts/ext-tool.sh secret <team> <name> --from-clipboard
   ```
   This reads `pbpaste`/`wl-paste`/`xclip`/`xsel`/PowerShell's
   `Get-Clipboard` (whichever exists) and saves the value straight to a
   0600 file, answering only "Saved to `<path>`. (The value itself is not
   shown or logged.)" — you never see the key, only that path. Take
   `<path>` from that line and use it as `<key_file>` below. If there is no
   clipboard access (a headless environment, or the read fails), fall back
   to asking the user to run it in a real terminal themselves instead,
   without `--from-clipboard`:
   ```
   bash <skill-root>/scripts/ext-tool.sh secret <team> <name>
   ```
   which prompts and reads the key without echoing it — this form needs a
   real TTY, which is why it cannot run through you inside Claude Code's own
   `!` passthrough. It reports the same "Saved to `<path>`." line; ask the
   user to read it back to you since you did not run this form yourself.
   **Never accept a pasted key value in chat.**

   Then verify it is in place:
   ```
   bash <skill-root>/scripts/ext-tool.sh setup <team> <name> jev check key <key_file>
   ```
   - `{"ok":true}` → the file exists and is readable, continue.
   - `{"ok":false,"error":"key file not found: ..."}` → the save above
     didn't land at that path; re-run step 2.
   - `{"ok":false,"error":"key file does not hold a single-line key: ..."}`
     → the clipboard held something else (e.g. a multi-line paste); copy
     just the key and re-save.

3. **Save the member config, then run a real test.**
   ```
   bash <skill-root>/scripts/ext-tool.sh setup <team> <name> jev save <key_file>
   bash <skill-root>/scripts/ext-tool.sh setup <team> <name> jev test
   ```
   `ext-tool.sh` resolves and passes the member config path itself for both
   of these — you only ever supply `<key_file>`. `test` calls the real
   OpenRouter once with a trivial example question and prints the actual
   answer JSON (including `usage.cost`) so the user can see it worked and
   what it costs. This is the ONE path in this tool that calls the real API
   from a conversational setup flow — it only runs when a human asked for
   it here, with their own real key; it is never exercised in CI.

## Common failures, and what actually fixes them

| error | what it means | fix |
|---|---|---|
| `key file not found or not readable: ...` | the configured path doesn't exist, or isn't readable by this user | re-check step 2's save, or fix the file's permissions |
| `key file is empty: ...` | the file exists but has nothing in it | re-copy the key and re-save |
| `key file does not hold a single-line key: ...` | the file has whitespace or more than one line in it | copy just the key (no surrounding text) and re-save |
| invalid API key (HTTP 401) | the key is wrong or was revoked | get a fresh key from <https://openrouter.ai/keys>, re-save |
| rate limited (HTTP 429) | too many requests too fast | wait a few seconds and retry; not a configuration problem |
| a one-line message naming `curl`, a host, or a timeout | `handle`/`setup` couldn't reach the API at all (DNS, network, TLS) | check the machine's network; if `AGMSG_JEV_API_BASE` is set in the real environment (it should only be set by the test suite), unset it — a value left over from testing silently redirects real calls nowhere |
| `jev: unexpected response shape` | OpenRouter answered but not in the shape this tool expects | the API may have changed; this needs a code fix, not a setup fix |
