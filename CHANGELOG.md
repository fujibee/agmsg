# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.8] - 2026-07-15

### Added
- Sidebar per-section + buttons, replacing the New dropdown (#407)
- Green status-unknown default, roomier team-status-rail rows (#406)
- Phase-lock agent-status and monitor pulse dots to wall clock (#403)
- Detect grok/grok-build agent status (#395)
- Persist UI settings across restarts (#391)
- Snap pane dividers to terminal cell units, herdr-style gaps (#390)
- Show agent and team status (#385)

### Fixed
- Filter non-numeric characters out of the font-size draft (#405)
- Reject unregistered from/to agents (#409)
- Resolve Codex leftovers and delivery_modes mismatch (#408)
- Forward args on a flags-only monitored launch (#404)
- Clean up the Settings font-size input (#401)
- Display chat timestamps in local time, not raw UTC (#394)
- Normalise Windows backslash paths before handing to bash/curl (#392)

### Performance
- Batch pty-output writes to one term.write() per animation frame (#402)

## [app-v0.1.5] - 2026-07-13

### Added
- 0.1.5 UI polish — sidebar collapse, chat pane min/max, Team Room toggle, About version, lucide icons (#377)

### Fixed
- Authenticode-sign Windows binaries during tauri build (#354)

## [1.1.7] - 2026-07-13

### Added
- Role-to-session affinity: named sessions, resume-by-role boot, tmux-resurrect (#339) (#344)

### Fixed
- Wrap boot script with bash -l for psmux on Windows (#335) (#363)
- Guard '/'-prefixed boot prompt against MSYS path conversion on Git Bash (#358)
- Stop ancestor project resolution from over-reaching to $HOME / other teams (#357) (#359)
- Bind the bridge to the role's recorded thread, not "loaded" (#350) (#353)
- Detect the real GEMINI_CLI env var, not GOOGLE_GEMINI_CLI (#351)

## [1.1.6] - 2026-07-05

### Added
- Aligned-grid seam-segment dragging + lazy transpose (issue #317, part 3) (#327)
- Wire pane split tree into rendering + drag-drop (issue #317, part 2) (#324)
- Pane split tree — pure data model + tests (issue #317, part 1) (#321)
- Expose pane layout in the View menu (#316)

### Fixed
- Correct boot script for Windows-tmux launch and per-type prefix (#282, #283) (#329)
- Strip inherited same-type session-identity env vars (#294) (#326)
- Match project registrations across Windows path forms (#268) (#328)
- Launch agents via cmd.exe on Windows so PATHEXT/aliases resolve (#314, #313) (#325)
- Resolve MSYS project paths to native on Windows spawn (#315) (#319)
- Normalize Windows drive-letter project path to POSIX before identity resolution (#275)

## [app-v0.1.3] - 2026-07-04

### Fixed
- Explicit PATH propagation to spawned processes, dscl shell fallback, diagnostic log (#312)
- V0.1.3 — import login shell PATH so agent spawn works from Finder (#311)

## [app-v0.1.2] - 2026-07-04

### Fixed
- Suppress bash's console window and profile-loading delay (#310)
- Fall back to USERPROFILE when HOME is unset (#309)
- Resolve Git Bash explicitly + bump version to 0.1.2 (#308)
- V0.1.2 — Windows bash path bug, banner overlap, update feedback (#306)

## [app-v0.1.1] - 2026-07-04

### Added
- Add update-cask.sh — automate the Homebrew tap bump (#304)

### Fixed
- V0.1.1 — agmsg-app pin fix, updater artifacts, outdated-CLI warning (#303)

### Documentation
- Add brew trust step to macOS install instructions (#301)

## [app-v0.1.0] - 2026-07-03

### Added
- Official agmsg desktop app (#298)

## [1.1.4] - 2026-07-03

### Added
- Add scripts/api.sh — read-only JSON entry point for non-bash consumers (#289)
- Enable spawn for antigravity, copilot, cursor, gemini, opencode (#278)
- Per-type spawn options via a configurable YAML file (#274)

### Fixed
- Fall back to a tarball download when git is unavailable (#296)
- Gate actas/drop's fresh Monitor on delivery mode (#280) (#281)
- Escape team/agent SQL values in history/inbox/check-inbox (#87) (#272)

### Documentation
- Add Japanese translations for Tier 1 contributor-facing docs (#291)
- AGMSG_HOME data-root override, env-var naming convention (#284)

## [1.1.3] - 2026-06-30

### Added
- Use brand logo mark + favicon set (#257)
- Redesign agmsg.cc landing with Astro + Tailwind (#213) (#249)
- Allow passing an initial prompt to the spawned agent (#212)

### Fixed
- Run watch-once.sh via bash so the codex bridge arms on Windows
- Prefer shell function monitor shim; skip agmsg wrapper when resolving real codex (#193)
- Drop monitor/both — Gemini has no Monitor tool (#258)
- Skip Monitor directive when watcher already alive (#246)
- Escape interpolated values as SQL string literals (#223)
- Add CIM fallback for /proc-less cmdline/comm (#225) (#234)
- Robust monitor — session-bind, orphan reaper, foolproof launch (#245)
- Report bridge liveness in delivery status (#232)
- Reject agent names that break JSON paths
- Pipe SQL via stdin to avoid ARG_MAX on large bodies

### Documentation
- Add agmsg logo asset kit (#255)

## [1.1.2] - 2026-06-27

### Added
- Add opt-in explicit-launch monitor delivery (#236)
- Add MSYS2 compat shim (#88) (#211)

### Fixed
- Start the watcher when GROK_SESSION_ID is empty (#236 follow-up) (#238)
- Keep Codex working across 0.142 upgrades (fail-open + stale app-server reuse) (#237)
- Serialize team config writes behind a per-team lock (#141) (#227)
- Open the message DB via a Windows-acceptable path (#197) (#226)
- Handle whoami suggest= identity and anchor agent= match (#224)
- Bound bridge app-server stalls (#209)

## [1.1.1] - 2026-06-25

### Added
- Add --model to launch a spawned agent on a chosen model (#220)
- Add grok-build agent type (xAI Grok Build CLI) (#216)

### Fixed
- Scope watcher teardown to (project, type), not project (#219)
- Exit on originating-session death so a quiet watcher can't hang (#67, #388) (#215)
- Quote Monitor command args so space-in-path survives (#188) (#200)
- Use tasklist for native pid liveness in agmsg_instance_alive (#134)

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

[1.1.8]: https://github.com/fujibee/agmsg/compare/app-v0.1.5...v1.1.8
[app-v0.1.5]: https://github.com/fujibee/agmsg/compare/v1.1.7...app-v0.1.5
[1.1.7]: https://github.com/fujibee/agmsg/compare/app-v0.1.4...v1.1.7
[1.1.6]: https://github.com/fujibee/agmsg/compare/app-v0.1.3...v1.1.6
[app-v0.1.3]: https://github.com/fujibee/agmsg/compare/app-v0.1.2...app-v0.1.3
[app-v0.1.2]: https://github.com/fujibee/agmsg/compare/app-v0.1.1...app-v0.1.2
[app-v0.1.1]: https://github.com/fujibee/agmsg/compare/v1.1.5...app-v0.1.1
[app-v0.1.0]: https://github.com/fujibee/agmsg/compare/v1.1.4...app-v0.1.0
[1.1.4]: https://github.com/fujibee/agmsg/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/fujibee/agmsg/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/fujibee/agmsg/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/fujibee/agmsg/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/fujibee/agmsg/compare/v1.0.6...v1.1.0
[1.0.6]: https://github.com/fujibee/agmsg/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/fujibee/agmsg/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/fujibee/agmsg/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/fujibee/agmsg/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/fujibee/agmsg/releases/tag/v1.0.2

