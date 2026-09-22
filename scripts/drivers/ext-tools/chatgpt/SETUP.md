# ChatGPT ext-tool setup

Read this when `join <team> <name> ext-tool --tool chatgpt` stops because no
member config exists yet. This is a guide for YOU (the seat LLM): `setup`
itself never talks to anyone — you run it, read its JSON, and decide what
to say next.

This member is not an API. It is a ChatGPT conversation living in a tab of
Orca's built-in browser, driven through `orca` CLI eval. There is no key
and no `secret` step.

**Do not hardcode any path, including `~/.agents/skills/agmsg`.** Derive
`<skill-root>` from wherever you actually found this file
(`<skill-root>/scripts/drivers/ext-tools/chatgpt/SETUP.md`); `ext-tool.sh`
under `<skill-root>/scripts/` resolves the member config path for you.

## What to ask the user

1. **Which Orca worktree hosts the ChatGPT tab?** A filesystem path; the
   tab must already be open and logged in. `orca tab list --worktree
   path:<path> --json` shows what is there.
2. **Which conversation?** Default `url_regex` `chatgpt\.com` matches any
   ChatGPT tab. To pin one thread, use `chatgpt\.com/c/<id>` from the tab's
   URL — recommended, since otherwise a user navigating the tab elsewhere
   moves where messages land.
3. **Mode.** `sync-wait` (default): each message waits for ChatGPT's reply
   and returns it as this member's agmsg reply (bounded by `timeout=300` in
   tool.conf). `inject-only`: messages are delivered and confirmed, replies
   are not collected — pair with your own transcript watcher if needed.
4. **Optional `judge_member`.** If the same team has a `jev` member, naming
   it here lets `handle` ask jev to arbitrate two ambiguous branches
   (unknown page state before reloading; whether a stable reply looks
   truncated). Unset = pure heuristics. Note: judging sends small page
   excerpts to jev's provider — see USAGE.md before enabling.

## The steps

```
bash <skill-root>/scripts/ext-tool.sh setup <team> <name> chatgpt check tab <worktree> [url_regex]
bash <skill-root>/scripts/ext-tool.sh setup <team> <name> chatgpt save <worktree> [url_regex] [mode]
bash <skill-root>/scripts/ext-tool.sh setup <team> <name> chatgpt test
```

`check tab` answers `{ok:true, tabs:N, page, title}` when at least one live
tab matches. `test` does ONE real round trip (injects a trivial prompt,
waits up to 120s, reports the reply head and latency) — run it once, it
leaves one exchange in the ChatGPT transcript.

Then `join.sh <team> <name> ext-tool --tool chatgpt` (or the seat's normal
join flow) will accept the member.

## Common failures

| error | meaning | fix |
|---|---|---|
| `orca tab list failed ...` | Orca not running, or the path is not a registered worktree | open Orca / check `orca worktree ps --json` |
| `no tab matching ...` | no ChatGPT tab in that worktree | open `chatgpt.com` in the worktree's browser, or fix url_regex |
| `tab not idle: GENERATING` at test | ChatGPT is busy | wait for it to finish, re-run test |
| `inject failed (composer-busy)` | the human has an unsent draft | send or clear the draft in the tab |
| `send not confirmed` | optimistic render rolled back, or send button never enabled | retry; check the tab is logged in |
| `reply did not complete before timeout` | generation exceeded the budget | long tasks don't fit sync-wait; switch the member to `inject-only` |
