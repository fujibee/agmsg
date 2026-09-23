# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report privately through GitHub's private vulnerability reporting for this repository:
https://github.com/fujibee/agmsg/security/advisories/new

Include what you found, how to reproduce it, and which version or commit you tested. We aim to acknowledge reports within 7 days, on a best-effort basis. Fixes ship in the next release; the advisory is published after the fix is available.

## Supported versions

Only the latest release on the main branch receives security fixes.

## Scope

agmsg is a local tool. It stores team messages on the user's machine, either in a SQLite file (the default) or in an append-only JSONL event log (an opt-in storage driver) — either way, the store stays local unless remote sync is explicitly configured. It runs adapters (ext-tool) on the sender's machine. Secrets for ext-tool members are written to files with 600 permissions and are never printed to chat, message history, or logs. Reports about any of these paths are welcome, as are reports about the optional remote sync.
