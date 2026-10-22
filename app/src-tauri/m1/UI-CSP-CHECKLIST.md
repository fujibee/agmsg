# Click-through: the app UI under the new Content-Security-Policy

The main window now has a CSP (`app.security.csp` in `tauri.conf.json`) and every app command is behind an explicit ACL. A quick automated check showed the first seconds of the UI are clean. This page is for a person to use the app for about ten minutes and report anything the policy broke. A break shows up as a missing feature, a blank area, or a `Refused to …` line in the devtools console.

## 1. Launch a debug build with its own identity

It uses its own app identifier (so it never forwards to an installed agmsg app, and does not touch its settings) and a **copy** of the agmsg home (so renames and deletes in this session cannot touch your real teams).

```
cp -R ~/.agents/skills/agmsg /tmp/agmsg-csp-check            # a copy of the data this build will read and change
cd app && pnpm install --frozen-lockfile && pnpm build       # frontend, embedded into the binary
cd src-tauri
mkdir -p resources/agmsg-core && echo stub > resources/agmsg-core/PLACEHOLDER   # not used in this check
export TAURI_CONFIG='{"identifier":"cc.agmsg.csp-check"}'
cargo build --features tauri/custom-protocol                 # debug build; devtools are available in it
AGMSG_APP_BASE=/tmp/agmsg-csp-check ./target/debug/agmsg-app
```
Run the same with `cargo build --release --features tauri/custom-protocol` and `./target/release/agmsg-app` for the release pass (devtools are not available in release: watch for features that do not work instead).

Do **not** set `HOME` to anything else. Delete `/tmp/agmsg-csp-check` when done.

## 2. See CSP violations

Debug build only: right-click anywhere in the window → **Inspect Element** → **Console**. Keep it open for the whole session. A violation looks like
`Refused to load/execute/apply … because it violates the following Content Security Policy directive: "…"`.
Write down the directive and the blocked URL or kind (`script`, `style`, `image`, `font`, `connect`, `frame`).

Expected and fine: one `frame-src` line about `…/__agmsg_probe_nav__` and one about `eval` from the add-on startup probe, within the first ten seconds. Anything else is a finding.

The terminal line of the process shows `[addons] startup check: enabled=true` a few seconds after launch. If it says `enabled=false`, copy the reason.

## 3. What to use

Tick each one; note "ok" or what broke.

- [ ] Sidebar loads teams and members; the team room shows messages and keeps updating when a message arrives (send one from a terminal: `~/.agents/skills/agmsg/scripts/send.sh <team> <from> <to> "csp check"`, with `AGMSG_APP_BASE` pointing at the copy if the script honours it).
- [ ] **Terminal pane**: spawn an agent or shell pane; type, paste, scroll; colours and box-drawing look right (this is the xterm WebGL renderer: a blank or garbled terminal is a finding).
- [ ] Resize the window and the panes (drag a split, change the layout from the menu: vertical / horizontal / tile); the terminal re-fits.
- [ ] Move a pane to another tab; swap two panes; close a pane.
- [ ] **Zoom**: View → zoom in / out / reset.
- [ ] **Settings** (open it, change the language, change every toggle, close it).
- [ ] **Every dialog**: open and cancel each one — new team, new agent, join, rename, rename team, delete team, purge messages, delivery mode, update-core / install prompts, about, check for updates.
- [ ] **New team** and **new agent** end to end in the copy.
- [ ] **Rename** an agent and a team.
- [ ] **Chat composer** (the user chat box): type, send a message, send a long one, a multi-line one; the message appears in the room.
- [ ] Theme / dark mode switch if the UI has one; logo and avatar images render; fonts look normal.
- [ ] Drag a file onto the window (the window accepts drops); nothing breaks.
- [ ] Leave it running five minutes with a terminal pane producing output; no new console lines.

## 4. Report

Per finding: what you did, what you expected, what happened, the console line (copy it whole), debug or release. "No violations in N minutes of use, all items ticked" is also a result worth sending.
