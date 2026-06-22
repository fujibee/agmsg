# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-06-22

### Added
- Add Cursor agent type (#189)
- Add Hermes Agent as a beta agent type
- Axis-generic driver discovery + external-plugin opt-in
- Drop the aliases= auto-redirect; explicit type selection only
- Pluggable agent-type registry

### Fixed
- Warn to re-register delivery hooks on --update (#190)
- Re-point an existing Codex monitor shim on --update
- Follow init-db move to internal/ in the Windows PowerShell smoke
- Readfile() config binding for single-quote-safe registry (#185)
- Strip CR from sqlite3 output so Windows Git Bash works (#180)
- Git Bash compatibility for the Codex bridge (#179)
- Cut-release.sh stops at the PR (no auto-merge / auto-publish) (#177)

### Changed
- Drop the Windows PowerShell launcher in favor of Git Bash
- Relocate types/ under scripts/drivers/types/
- Consolidate mode support into delivery_modes manifest
- Data-drive Windows hook wrapping via manifest
- Status as a Template Method plug
- Fold the codex runtime into types/codex/
- Move enable/disable side effects into type plugs
- Wire SKILL templates to type-dir manifests
- Extract codex bridge handoff into a type plug
- Drive Stop-hook status output from manifest stop_output=
- Per-type delivery as a Template Method plug
- Extract hook JSON primitives into lib/hooks-json.sh
- Move init-db to internal/, dispatch to windows/, drop hook.sh
- Move the codex subsystem into scripts/codex/

### Documentation
- Add supported-agents logo strip
- List hermes in the --agent-type help (co1 nit)
- Add docs/plugins.md + README section + plugins/ drop-in dir
- Refresh manifest table + paths for the 1.1.0 layout
- Lead Quick Start with npx, the zero-clone install path

## [1.0.6] - 2026-06-21

### Added
- Codex monitor bridge (beta) — app-server bridge + re-arm + fresh-session launch (#41) (#148)
- Add OpenCode as a supported agent type (#136)

### Fixed
- Pin install to the bootstrapper's version, not main (#173)
- Engage the monitor bridge on codex 0.141 (ws transport + loaded-thread discovery) (#174)
- Escape hook command values via json_object (#175)
- Stop orphaned watch.sh from advancing the shared watermark past undelivered messages (#145)
- Resolve Codex thread by physical path so symlinked project paths match (#160) (#164)
- Validate writefile() byte count, not just sqlite3 exit code (#166)
- Pass sqlite3 -escape off so the char(31) separator stays raw (#165)
- Write hook files with writefile() to avoid sqlite3 caret-escaping (#158)
- Validate team names to prevent teams/ path traversal (#147)

### Documentation
- Worker guardrails + empty-poll OOM case study (#163) (#167)
- Add llms.txt for AI-agent orientation (#155)

## [1.0.5] - 2026-06-17

### Added
- Add thin Windows PowerShell launcher (#128)
- Tear down spawned crew members (#109) (#129)

### Fixed
- Isolate parallel --continue/--resume sessions sharing a session_id (#132)

## [1.0.4] - 2026-06-15

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

### Documentation
- Show all four install paths (#90)

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

[1.1.0]: https://github.com/fujibee/agmsg/compare/v1.0.6...v1.1.0
[1.0.6]: https://github.com/fujibee/agmsg/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/fujibee/agmsg/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/fujibee/agmsg/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/fujibee/agmsg/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/fujibee/agmsg/releases/tag/v1.0.2

