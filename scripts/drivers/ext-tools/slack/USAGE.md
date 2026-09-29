# Sending to a Slack ext-tool member

Read this when you (the sending seat) are about to `agmsg send <team> <name>
"<body>"` to a member whose type is `ext-tool --tool slack`. Setting one up
is a different job with its own guide — see `SETUP.md` next to this file —
this page is only about what happens once it's already configured.

## What it does

Posts to **one fixed Slack channel**, decided once during setup and not
something you choose per message. **On success there is no reply** — the
message goes out and that's the end of it, you are not woken up again to
learn whether it landed. **On failure you do get one reply**, later, one
line naming what went wrong (see below) — that is the only case where
sending here wakes your seat again.

## What you send

Whatever you put in `<body>` is posted with **no reformatting, no
wrapping, no "as a Slack message" rewriting** — write it the way you want
it to appear in Slack, including any Slack markdown you want rendered
(`*bold*`, `` `code` ``, links, etc.). The body text is otherwise passed
through unchanged, with one exception: trailing newlines are stripped
before it reaches Slack, so don't rely on trailing blank lines for
spacing.

## Before you send

- **The channel is fixed by ID**, chosen when this member was set up. You
  cannot redirect a single message to a different channel; if the wrong
  channel is a real problem, that's a setup change, not a per-message one.
- **A sent post cannot be retracted through this path.** There is no
  "unsend" — if you need something un-posted, that's a manual fix in Slack
  itself, by whoever has access there.

## If it fails

A failed send comes back as one line naming the reason. The ones you'll
actually see:

| what it says | what actually happened |
|---|---|
| `not_in_channel` | the bot isn't a member of the destination channel |
| `invalid_auth` | the saved bot token is wrong or was revoked |
| `missing_scope` | the Slack app is missing a permission it needs |
| `rate limited (HTTP 429)` | too many posts too fast — not a config problem, just timing |
| a line naming `curl`, a host, or a timeout | couldn't reach Slack's API at all |

None of these are something you can fix by resending with different
wording — retrying `not_in_channel`/`invalid_auth`/`missing_scope` will fail
the same way every time until someone with access reruns setup (see
`SETUP.md`). Rate limiting and network failures are the two exceptions
where a later retry can genuinely succeed on its own.
