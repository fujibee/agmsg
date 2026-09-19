# ext-tool adapters

An ext-tool is a program, not a human or an AI CLI, joined into a team as a
member. Adding one is dropping a directory here:

```
scripts/drivers/ext-tools/<tool>/tool.conf   # name, required config keys, default timeout
scripts/drivers/ext-tools/<tool>/SETUP.md    # for the LLM at the joining seat: what to ask, in what order, common failures
scripts/drivers/ext-tools/<tool>/setup       # non-interactive: status | check <item> | save | test
scripts/drivers/ext-tools/<tool>/handle      # processes one message
```

An adapter can be written in any language; agmsg only talks to it over
argv/stdin/stdout/exit-code.

## `tool.conf`

Read-only `key=value` data, never sourced. Recognized keys:

```
name=<tool>
timeout=<seconds>       # handle's per-call budget (default 30 if absent)
```

## `setup`

Never interactive — nothing in `setup` talks to a terminal or asks a
question. The conversation happens at the LLM seat that reads `SETUP.md` and
calls `setup` once per step:

```
setup status <config_path>                # -> JSON: what's still missing
setup check <item> <config_path>           # -> confirm one thing works (a token is valid, a channel exists, ...)
setup save <config_path>                   # -> write the member's config (0600); reads any needed values from its own env/args, never prompts
setup test <config_path>                   # -> actually try sending one message end to end
```

`<config_path>` is the member's own config file
(`~/.agents/skills/agmsg/ext-tools/<team>/<name>.conf`); `scripts/ext-tool.sh
setup` is what a seat actually runs, and it resolves this path before calling
into the tool's own `setup`. A tool that needs a secret value never reads it
itself — the human runs `scripts/ext-tool.sh secret <team> <name>` directly in
their own terminal, and the tool's config only ever names *where* that secret
was written (e.g. `key_file=...`), never the value.

Exit 0 on success; non-zero on failure, with one line of reason on stderr.

## `handle`

Runs once per inbound message, in the background, not waited on by the
sender.

- stdin: one JSON object —
  `{team, from, to, body, subject?, question?, message_id, config_path}`.
- stdout: the reply body. Empty stdout means no reply is sent (a fire-and-forget
  tool).
- exit code: 0 = success. Non-zero = failure; agmsg sends
  `"<name>: processing failed (<one-line reason>)"` as the reply instead of
  staying silent. The reason is `handle`'s own first stderr line, if any.
- Timeout: `tool.conf`'s `timeout=` (default 30s). A `handle` that runs past it
  is treated as a failure.
- Secrets: `config_path` may reference a key file (`key_file=...`); `handle`
  reads it itself. Never echo a secret's contents to stdout, stderr, or any
  agmsg message — that becomes the reply body, and replies are ordinary
  messages that land in history.

No ext-tool adapter runs as a standing process. `handle` starts, does its one
job, and exits — matching every other channel here, delivery to an ext-tool
member happens only through a `send`/`sync` this machine already made,
never through anything the tool itself initiates.
