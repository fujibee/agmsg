# Privacy Policy

**Last updated:** 2026-10-01

This privacy policy describes how the open-source **agmsg** project (the CLI and desktop app at https://github.com/fujibee/agmsg, distributed via [agmsg.cc](https://agmsg.cc), the Anthropic / OpenAI / community plugin and skill marketplaces, and the `agmsg` npm package) handles user data. It does not cover any hosted service.

## The core

- **Data stays on the user's machine.** Teams, messages, and settings are stored locally, mostly under `~/.agents/` and in the configuration of the projects the user joins agmsg to.
- **No data collection, no telemetry.** The agmsg project does not collect, receive, sell, or disclose user data, and sends no usage data or analytics.
- **No agmsg accounts.** agmsg has no accounts or login.
- **No outside communication by default.** The CLI does not contact other machines unless the user turns on a feature that does.

## Extensions and integrations

Features the user turns on, such as remote sync, external tool integrations, and plugins, communicate with the destinations the user configures for them. What is sent depends on the feature. Anything sent goes where the user pointed it, not to the agmsg project.

## Installing and updating

Installing agmsg downloads it from GitHub. The desktop app checks GitHub for new versions; it installs an update only after the user approves it, and verifies the update's signature.

## Other tools

agmsg works alongside the AI agent tools the user has installed, but does not call their services itself. What the user sends to those tools is governed by their own privacy policies.

## Children's privacy

agmsg does not collect data from anyone, including children. The software is a developer tool intended for use by users 13 and older in accordance with the underlying agent tools and their respective terms.

## Changes to this policy

If agmsg begins to collect data or to use the network in a way not described here, this policy will be updated and the change announced in the project repository's [`CHANGELOG`](https://github.com/fujibee/agmsg/commits/main) or release notes. The current version of this policy lives at:

https://github.com/fujibee/agmsg/blob/main/PRIVACY.md

## Contact

Questions or concerns about this policy can be raised by:

- Opening an issue at https://github.com/fujibee/agmsg/issues, or
- Emailing the maintainer at **fujibee@gmail.com**.

## License

The agmsg project itself is MIT-licensed. See [`LICENSE`](https://github.com/fujibee/agmsg/blob/main/LICENSE).
