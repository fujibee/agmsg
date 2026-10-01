# Privacy Policy

**Last updated:** 2026-10-01

This privacy policy describes how the open-source **agmsg** project (the CLI and desktop app at https://github.com/fujibee/agmsg, distributed via [agmsg.cc](https://agmsg.cc), the Anthropic / OpenAI / community plugin and skill marketplaces, and the `agmsg` npm package) handles user data. It does not cover any hosted service.

In short: **agmsg does not collect user data and has no telemetry or analytics.** Messages, teams, and settings are stored on the user's machine. By default the CLI makes no network requests; the only cases where agmsg talks to a network are listed under [Network access](#network-access).

## What data agmsg handles

When installed, agmsg stores the following on the user's local filesystem only:

- **Team and agent identity registry** — JSON files under `~/.agents/skills/agmsg/teams/<team>/config.json`. Contains team names, agent names within each team, the agent type label (`claude-code`, `codex`, `gemini`, `antigravity`, `copilot`, `opencode`), and project paths the user joined from. The user explicitly chooses every value at join time.
- **Messages sent between local agents** — rows in `~/.agents/skills/agmsg/db/messages.db`, an SQLite file. The message body, sender, recipient, team, and timestamp are stored. The user (or the agent acting on their behalf) chooses every value when invoking `send.sh`.
- **Per-session runtime files** — pidfiles, last-checked markers, and the actas exclusivity lock files under `~/.agents/skills/agmsg/run/`. These reference the user's session IDs and process IDs to coordinate hooks.
- **Hook configuration in the user's projects** — agmsg writes per-runtime hook files (e.g. `<project>/.claude/settings.local.json`, `<project>/.codex/hooks.json`, `<project>/.agent/rules/agmsg.md`, `<project>/.github/hooks/agmsg.json`) when the user picks a delivery mode. These contain absolute paths to the agmsg scripts; they do not contain personal data beyond filesystem paths.

All of the above lives on the user's machine. The current version has no resident daemon and no server that accepts connections from other machines. Background processes that may run: the inbox watcher (local files only); for a Codex seat, the Codex monitor, which starts `codex app-server` listening on `127.0.0.1` only, plus a bridge that connects to it; and, for a team connected to a remote server, the sync engine (see [Network access](#network-access)).

"Network access" in this policy means a connection to another machine. Connections on `127.0.0.1` stay on the user's machine and are not counted.

## What agmsg does not do

- **No network requests by default in the CLI.** Sending, the inbox, history, teams, joining, and the watcher use only local files and the SQLite database. The exceptions are listed under [Network access](#network-access).
- **No telemetry or analytics.** No usage data, error reports, or counts are sent anywhere.
- **No third-party services.** agmsg integrates with whatever CLI AI agent the user has installed (Claude Code, Codex, Gemini CLI, Copilot CLI, Antigravity, OpenCode); it does not call those agents' backends itself. Anything the user types to one of those agents is governed by that agent's own privacy policy, not by agmsg.
- **No agmsg accounts.** agmsg has no user accounts and no login. Services the user connects bring their own credentials, which the user supplies (for example an ext-tool member's API key or token, kept in a file on the user's machine that the member's config names).
- **No data sharing.** The agmsg project does not receive, sell, or disclose user data. Data leaves the machine only in the cases under [Network access](#network-access).

## Network access

agmsg uses the network only in the cases below.

**Installing the CLI.** `npx agmsg install` downloads the installer from `raw.githubusercontent.com`, and the installer fetches the agmsg source from `github.com` (`git clone`, or a tarball if git is unavailable). This happens only when the user runs the install.

**Desktop app update check.** The desktop app requests `https://github.com/fujibee/agmsg/releases/download/app-latest/latest.json` each time it starts, and when the user picks "Check for Updates". The startup check cannot be turned off in the app today. As with any HTTPS request, GitHub can see the requesting IP address. An update is installed only after the user approves it, and its signature is verified against the public key built into the app. Starting agents and sending messages from the app go through the same CLI scripts, so they need no network.

**Remote sync (opt-in).** A team syncs only after the user runs `remote.sh connect` (or `pull`) with `--endpoint <url>`; there is no default server. The sync engine then exchanges that team's data with the server the user named: messages, sender and recipient names, the member roster, and read state. Teams that are not connected send nothing. `--e2ee` encrypts message bodies before they leave the machine, and `remote.sh disconnect` stops syncing for a team.

**External tool members (opt-in).** An ext-tool adapter is a program joined into a team as a member (for example the `slack` and `jev` adapters that ship with agmsg). It contacts the service the user configured for it when a message is addressed to it, and when the user sets it up or tests it. What it sends is up to the adapter.

## Where data is stored

agmsg writes to the user's local filesystem. The main default locations are:

- `~/.agents/skills/agmsg/` (the skill directory)
- `~/.agents/agmsg/config.json` (the machine-wide settings file, for example the storage driver)
- `~/.agents/bin/` (small launcher shims for some agent types)
- `<project>/.claude/`, `<project>/.codex/`, `<project>/.agent/`, `<project>/.github/hooks/` (per-project hook configs, in the user's own project directories)
- the Codex configuration file (`config.toml` under `CODEX_HOME`, default `~/.codex/`), where the installer adds the paths agmsg needs to write to

Some locations can be overridden through environment variables (for example the message database directory and the settings file). `uninstall.sh` removes an install's skill, commands, and hooks (see its options, such as `--keep-data`); it does not guarantee that every location above is gone, so anything left can be deleted by hand.

## Inter-agent messages on the same machine

When two agents on the same machine use agmsg to communicate, the message body is written to `messages.db` by the sender and read back by the recipient when their hook fires. Unless the team is connected to a remote server or the message is addressed to an external tool member (see [Network access](#network-access)), the bytes never leave the user's filesystem. Whether the *content* of those messages is sensitive is up to the user — agmsg treats the body as opaque text.

## Children's privacy

agmsg does not collect data from anyone, including children. The software is a developer tool intended for use by users 13 and older in accordance with the underlying agent CLIs (Claude Code, Codex, etc.) and their respective terms.

## Changes to this policy

If agmsg begins to collect data or to use the network in a way not described here, this policy will be updated and the change announced in the project repository's [`CHANGELOG`](https://github.com/fujibee/agmsg/commits/main) or release notes. The current version of this policy lives at:

https://github.com/fujibee/agmsg/blob/main/PRIVACY.md

## Contact

Questions or concerns about this policy can be raised by:

- Opening an issue at https://github.com/fujibee/agmsg/issues, or
- Emailing the maintainer at **fujibee@gmail.com**.

## License

The agmsg project itself is MIT-licensed. See [`LICENSE`](https://github.com/fujibee/agmsg/blob/main/LICENSE).
