# agmsg desktop app

The official agmsg desktop app (macOS/Windows, desktop-first): a terminal-embedded
GUI that spawns agents in real PTYs and delivers agmsg messages to ANY interactive
CLI agent by injecting them into the agent's stdin at its idle prompt — no per-agent
bridge, hook, or monitor tool.

> Status: past Phase 0 — daily-driven, macOS-signed and notarized, auto-updating.
> Windows code signing and an automated release pipeline are still pending; until
> those land, builds are cut locally and installed by hand.

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

## Releasing (macOS)

```sh
cd app
pnpm build:notarize   # sources APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID from
                       # the worktree-root .env (never committed) and runs
                       # `tauri build`, which signs and notarizes automatically
                       # once macOS.signingIdentity is set in tauri.conf.json
```

Auto-update is wired up via `tauri-plugin-updater`, checked silently on launch and
on-demand via **agmsg app → Check for Updates…**. The private signing key lives in
the worktree-root `.secrets/` (never committed) and isn't yet wired into a CI
release job, so cutting a release still means building and uploading by hand.

The updater endpoint points at a **fixed tag**, `app-latest`
(`releases/download/app-latest/latest.json`) — deliberately NOT
`releases/latest/download/...`. `fujibee/agmsg` also hosts the CLI's own
releases (`v*.*.*`, cut far more often than the app), and GitHub's "latest
release" is whichever was published most recently across the whole repo,
not scoped by tag pattern — pointing at it would work right after an app
release and silently break again the next time the CLI ships. `app-latest`
sidesteps that: it's a single release whose assets get replaced every time,
never "the latest release" in GitHub's sense, so the URL never moves.

To cut a release:
```sh
cd app
pnpm build:notarize

# One-time: create the fixed pointer release if it doesn't exist yet.
gh release create app-latest --repo fujibee/agmsg --title "agmsg app (latest)" \
  --notes "Always points at the newest agmsg app build. See app-vX.Y.Z releases for changelogs." --prerelease

# Every release: also cut a normal versioned release for history/changelog...
gh release create app-vX.Y.Z --repo fujibee/agmsg --title "agmsg app vX.Y.Z" \
  src-tauri/target/release/bundle/macos/*.app.tar.gz \
  src-tauri/target/release/bundle/macos/*.app.tar.gz.sig \
  src-tauri/target/release/bundle/dmg/*.dmg

# ...then overwrite app-latest's assets with the same build + latest.json
# (hand-author latest.json: version, notes, pub_date, per-platform url+signature).
gh release upload app-latest --repo fujibee/agmsg --clobber \
  src-tauri/target/release/bundle/macos/*.app.tar.gz \
  src-tauri/target/release/bundle/macos/*.app.tar.gz.sig \
  latest.json
```

## Known gaps

- Windows code signing (Azure Artifact Signing account is provisioned; not yet
  wired into the build).
- No CI pipeline builds/publishes the app — `.github/workflows/release.yml` is the
  agmsg CLI's npm release and doesn't touch `app/`.
- No automated tests for the Tauri app itself.
