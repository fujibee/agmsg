# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Record git-describe provenance version (/agmsg version) (#122)
- Add native Windows agmsg helpers (#103)
- Readiness handshake by default (status=ready / --no-wait / --ready-timeout) (#113)
- Launch a new agent into tmux/terminal and auto-actas (#105)

### Fixed
- Busy_timeout on all DB connections — concurrent writes no longer drop (SQLITE_BUSY) (#115)
- Make the `monitor` mode and `delivery.sh set` work under Claude Code's sandboxed Bash tool (#106)
- Persist per-session watermark so restarts don't drop messages (#107) (#111)
- Resolve session's real project from subdir/worktree (#92) (#110)

## [1.0.3] - 2026-06-11

### Fixed
- Download setup.sh to a tempfile instead of piping curl into bash (#98) (#100)
- Refuse interactive prompt when stdin is not a tty (#98) (#99)
- Avoid E2BIG on large settings.local.json (#95) (#97)

### Documentation
- README + agmsg.cc rework for PH-launch traffic conversion (#94)

## [1.0.2] - 2026-06-08

### Added
- Add CLI type auto-detection (#69)
- Add .claude-plugin/ manifests for Claude Code plugin marketplace (#81)
- Add GitHub Copilot CLI support (turn mode) (#74)
- Actas exclusivity lock — fix same-team multi-identity message leakage (#62) (#65)
- Override message store path via AGMSG_STORAGE_PATH (#59)
- Add support for gemini and antigravity (agy) agents (#45)

### Fixed
- Unblock npm Trusted Publisher OIDC + bin path
- Support native Windows (Git Bash + Codex hooks) (#73)
- Scope set turn/off watcher kill to the target project (#86)
- SKILL.md self-bootstrap and substitute name placeholder (#83) (#85)

### Documentation
- Add PRIVACY.md (required by Anthropic community marketplace submission) (#82)
- Handle empty TaskList explicitly to stop fresh-session loop (#71)
- Storage driver pluginization design (epic #51) (#52)

[1.0.3]: https://github.com/fujibee/agmsg/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/fujibee/agmsg/releases/tag/v1.0.2

