# Privacy Policy

**Last updated:** 2026-10-01

This privacy policy describes how the open-source **agmsg** project (the CLI and desktop app at https://github.com/fujibee/agmsg, distributed via [agmsg.cc](https://agmsg.cc), the Anthropic / OpenAI / community plugin and skill marketplaces, and the `agmsg` npm package) handles user data. It does not cover any hosted service.

In short: **agmsg does not collect user data and has no telemetry or analytics.** Messages, teams, and settings are stored on the user's machine, and the CLI does not contact the outside world by default.

## What data agmsg handles

agmsg stores the following on the user's machine:

- **Team and agent registry** — team names, agent names, agent type labels, and project paths. The user chooses these values when joining a team.
- **Messages** — the message body, sender, recipient, team, and timestamp, in a local database. The user (or the agent acting for them) chooses these values when sending.
- **Runtime coordination files** — small files such as process and session identifiers that agmsg uses to coordinate its own background work.
- **Configuration** — agmsg's own settings, plus hook and configuration files that agmsg adds to the user's projects and to the agent tools it integrates with. These hold paths and settings, not personal data beyond filesystem paths.

Typical locations are listed under [Where data is stored](#where-data-is-stored).

## What agmsg does not do

- **No telemetry or analytics.** No usage data, error reports, or counts are sent to the agmsg project.
- **No data collection or sharing by the project.** The agmsg project does not receive, sell, or disclose user data.
- **No agmsg accounts.** agmsg has no user accounts and no login. Services the user connects to bring their own credentials, which the user supplies.
- **No calls to the agent tools' backends.** agmsg works alongside the AI agent CLIs the user has installed (such as Claude Code, Codex, Gemini CLI, Copilot CLI, Antigravity, and OpenCode) but does not call their services itself. What the user sends to those tools is governed by their own privacy policies.

## Network access

By default the CLI does not communicate with other machines: sending, reading, and managing messages and teams happen on the local machine. agmsg communicates over the network in these situations:

- **Features the user turns on.** Remote sync connects a team to a server the user specifies, and exchanges that team's data (such as messages, names, the roster, and read state) with it; end-to-end encryption is available as an option. External tool integrations contact the service the user configured for them. Each only runs for what the user has set up, and what is sent is determined by that feature or integration.
- **Installing agmsg.** The installer downloads agmsg from GitHub.
- **Desktop app updates.** The desktop app checks GitHub for a newer version when it starts and on request. It installs an update only after the user approves it, and verifies the update's signature.

As with any network request, the server contacted can see the requesting IP address. Some of agmsg's background components talk to each other on the user's own machine; that does not leave the machine and is not counted as network access here.

## Where data is stored

agmsg writes to the user's local filesystem. Typical locations include:

- `~/.agents/skills/agmsg/` — the skill directory, including teams, messages, and runtime files
- `~/.agents/agmsg/` — agmsg's settings
- per-project hook and configuration directories (such as `<project>/.claude/`, `<project>/.codex/`, `<project>/.agent/`, `<project>/.github/hooks/`)
- the configuration files of the agent tools agmsg integrates with, where the installer adds what agmsg needs

Some locations can be changed through environment variables. `uninstall.sh` removes an install's skill, commands, and hooks (see its options, such as `--keep-data`); anything left can be deleted by hand.

## Inter-agent messages on the same machine

When agents on the same machine communicate through agmsg, messages are written to the local database by the sender and read back by the recipient. Unless the team uses a network feature described above, they stay on the user's machine. Whether the *content* of messages is sensitive is up to the user; agmsg treats message bodies as opaque text.

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
