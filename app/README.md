# agmsg desktop app

The official agmsg desktop app (macOS/Windows, desktop-first): a terminal-embedded
GUI that spawns agents in real PTYs and delivers agmsg messages to ANY interactive
CLI agent by injecting them into the agent's stdin at its idle prompt — no per-agent
bridge, hook, or monitor tool.

> Status: past Phase 0 — daily-driven, macOS-signed and notarized, auto-updating.

## Install

**macOS**
```sh
brew tap fujibee/agmsg && brew trust fujibee/agmsg
brew install --cask agmsg
```
(`brew trust` is required on recent Homebrew versions, which refuse to load
casks from untrusted third-party taps.)
or download the `.dmg` directly from the [Releases page](https://github.com/fujibee/agmsg/releases) —
look for the newest `app-vX.Y.Z` tag. The app is signed and notarized, so it opens
normally with no Gatekeeper right-click workaround needed.

**Windows**
Download the `.msi` or `.exe` installer from the same [Releases page](https://github.com/fujibee/agmsg/releases).

Both platforms auto-update in place after install (**agmsg → Check for
Updates…**, or silently on launch).

Prerequisite either way: agmsg itself installed at `~/.agents/skills/agmsg` (the
app reads its DB and team config from there) — see the
[main README](../README.md) for that install.

## Strategic core — universal stdin-inject delivery

The app **owns** each spawned agent's pseudo-terminal. When a new agmsg message
arrives for a spawned pane, the app injects a short kickoff notice
(`[agmsg] <from>: "<preview>" — run /<cmd> to check it.`) into the agent's stdin
immediately — no idle-wait heuristics — followed by a deliberate ~300ms gap before
Enter (agents like Codex misread text+Enter written back-to-back as a paste and
swallow the Enter). The agent reacts as if a human typed it. Because this happens
at the PTY layer it is agent-agnostic — proven on both `claude` and a `python3` REPL
with the same code (see `poc-inject/`, the original Phase 0 proof).

## Stack

- **Tauri 2** (desktop shell).
- **React + TypeScript + Vite** frontend; **xterm.js** terminals.
- **portable-pty** (WezTerm crate) in Rust — direct, for full control of the PTY
  read loop + stdin injection.
- **rusqlite** read-only over agmsg's own SQLite DB for the view-only team room.
  Sending goes through agmsg's `send.sh` (the one sanctioned write path).

## Layout

```
app/
├── src/                 React frontend
│   ├── App.tsx          team select · member list · tabs · team room · composer
│   └── TerminalPane.tsx xterm.js view bound to a backend PTY session
├── src-tauri/src/
│   ├── pty.rs           PTY manager: spawn / write / resize / kill / inject
│   ├── agmsg.rs         read-only DB access + live watcher + send.sh bridge
│   └── lib.rs           Tauri builder, command registration, watcher start
└── poc-inject/          standalone Phase 0 (c) proof (reference; folds into src-tauri)
```

## Run (requires a GUI session)

```sh
cd app
pnpm install
pnpm tauri dev
```

Prerequisite: agmsg already installed at `~/.agents/skills/agmsg` (the app reads its
DB and team config from there). `claude` must be on `PATH` to spawn Claude Code panes.

### Try the core
1. Pick a team (top bar). The left list shows its members; the default tab is the
   view-only **team room**.
2. Click a member to spawn it in a PTY pane (a new tab).
3. From the bottom composer, send a message to that member as `app-user`. The app
   injects a kickoff notice into the agent's stdin right away and it responds.

## Releasing

`.github/workflows/app-release.yml` builds, signs, and (macOS) notarizes both
platforms on a push of an `app-vX.Y.Z` tag (or by hand via `workflow_dispatch`).
macOS goes through codesign → notarize → staple end to end in CI. Windows builds
and, given Azure credentials, runs Trusted Signing (OIDC via `azure/login`, no
client secret) — that federated identity trusts `main` only, so it can't be
exercised from a feature branch. The workflow deliberately doesn't publish a
GitHub Release itself; cutting one is still a human-gated step (upload artifacts
+ hand-author `latest.json`, below).

For a local macOS build without CI:
```sh
cd app
pnpm build:notarize   # sources APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID from
                       # the worktree-root .env (never committed) and runs
                       # `tauri build`, which signs and notarizes automatically
                       # once macOS.signingIdentity is set in tauri.conf.json
```

Auto-update is wired up via `tauri-plugin-updater`, checked silently on launch and
on-demand via **agmsg → Check for Updates…**. The private signing key lives in
the worktree-root `.secrets/` locally (never committed) and as the
`TAURI_SIGNING_PRIVATE_KEY`/`TAURI_SIGNING_PRIVATE_KEY_PASSWORD` secrets in CI.
`TAURI_SIGNING_PRIVATE_KEY` must be the **decoded** minisign key text itself
(two lines, starting with `untrusted comment:`) — not the base64-encoded form
`.secrets/agmsg-app-updater.key` is stored as on disk. Feeding the encoded file
straight into the secret fails with "failed to decode secret key: Missing
comment in secret key" the moment something (e.g. `createUpdaterArtifacts`)
actually exercises it, which can go unnoticed for a while if nothing does.

The updater endpoint points at a **fixed tag**, `app-latest`
(`releases/download/app-latest/latest.json`) — deliberately NOT
`releases/latest/download/...`. `fujibee/agmsg` also hosts the CLI's own
releases (`v*.*.*`, cut far more often than the app), and GitHub's "latest
release" is whichever was published most recently across the whole repo,
not scoped by tag pattern — pointing at it would work right after an app
release and silently break again the next time the CLI ships. `app-latest`
sidesteps that: it's a single release whose assets get replaced every time,
never "the latest release" in GitHub's sense, so the URL never moves.

To cut a release: push an `app-vX.Y.Z` tag (or run `app-release.yml` by hand) to
get signed artifacts out of CI, download them from the run, then:
```sh
# One-time: create the fixed pointer release if it doesn't exist yet.
gh release create app-latest --repo fujibee/agmsg --title "agmsg (latest)" \
  --notes "Always points at the newest agmsg build. See app-vX.Y.Z releases for changelogs." --prerelease

# Cut a normal versioned release for history/changelog, from CI's artifacts...
gh release create app-vX.Y.Z --repo fujibee/agmsg --title "agmsg vX.Y.Z" \
  <downloaded macOS .app.tar.gz, .sig, .dmg, Windows .msi, .exe>

# ...then overwrite app-latest's assets with the same build + latest.json
# (hand-author latest.json: version, notes, pub_date, per-platform url+signature).
gh release upload app-latest --repo fujibee/agmsg --clobber \
  <same artifacts> latest.json
```
Once artifacts are up, update the Homebrew cask (`fujibee/homebrew-agmsg`):
```sh
scripts/release/update-cask.sh X.Y.Z   # finds the .dmg on the release,
                                       # computes sha256, rewrites Casks/agmsg.rb,
                                       # commits and pushes the tap
```
Run it only after the release assets are uploaded — the cask's `url` must
resolve as soon as the tap commit lands.

## Known gaps

- Windows Trusted Signing is wired into CI but unverified end to end — its
  federated identity trusts `main` only, so every `feat/desktop-app` run fails
  at the Azure login step. First real signal comes from a `main`-branch run.
- No automated tests for the Tauri app itself.
