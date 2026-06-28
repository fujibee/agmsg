# agmsg desktop app

The official agmsg desktop app (macOS/Windows, desktop-first): a terminal-embedded
GUI that spawns agents in real PTYs and delivers agmsg messages to ANY interactive
CLI agent by injecting them into the agent's stdin at its idle prompt — no per-agent
bridge, hook, or monitor tool.

> Status: **Phase 0 (PoC)**. Local, unsigned. Validates the risky tech, not the full spec.

## Strategic core — universal stdin-inject delivery

The app **owns** each spawned agent's pseudo-terminal. When a new agmsg message
arrives for that agent, the app waits until the agent is at an idle/ready prompt
(silence debounce + optional ready-prompt match, so it never injects mid-generation)
and then writes the message into the agent's stdin. The agent reacts as if a human
typed it. Because this happens at the PTY layer it is agent-agnostic — proven on both
`claude` and a `python3` REPL with the same code (see `poc-inject/`).

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
3. From the bottom composer, send a message to that member as `app-user`. When the
   pane is idle, the app injects the message into the agent's stdin and it responds.

## Phase 0 scope

- (a) xterm.js pane spawning `claude` via PTY — done.
- (b) read agmsg DB → live team-room feed — done.
- (c) idle-detect stdin-inject delivery — done (proven end-to-end via the real
  agmsg path; see `poc-inject/`).

Deferred to later phases: pane/tab rearrange, multi-window, agmsg self-install,
code-signing/distribution, settings.
