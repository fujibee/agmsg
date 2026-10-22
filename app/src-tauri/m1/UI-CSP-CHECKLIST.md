# Click-through: the app UI under the new Content-Security-Policy

The main window now has a CSP (`app.security.csp` in `tauri.conf.json`) and every app command is behind an explicit ACL. A quick automated check showed the first seconds of the UI are clean. This page is for a person to use the app for about ten minutes and report anything the policy broke. A break shows up as a missing feature, a blank area, or a `Refused to …` line in the devtools console.

## 1. Launch

The binaries are prebuilt (`csp-check/agmsg-app-debug` and `csp-check/agmsg-app-release` under `app/src-tauri`) with their own app identifier `cc.agmsg.csp-check` (so they never forward to an installed agmsg app and keep their own window settings). They run against a **safe copy** of the agmsg home, made by `m1/make-check-copy.sh`: it leaves out the live daemon files (`run/`) and the cloud-sync state (`db/remote-sync/`), takes every message store with sqlite's own `.backup` (never a plain copy of a live WAL database), and prints any storage or sync line in the copied config for you to look at. Nothing in your real install is changed.

Run these from `app/src-tauri`, **one line at a time**:

```
d=$(mktemp -d)
m1/make-check-copy.sh "$d"
export AGMSG_APP_BASE="$d"
./csp-check/agmsg-app-debug
```
Release pass, later, in the same terminal:
```
./csp-check/agmsg-app-release
```

**Check that it uses only the copy.** On start the app prints one line, `[agmsg-app] resolved: <path> | <path> | …`: the agmsg base and every store it found. Every path in that line must start with the folder `mktemp` made (`echo "$d"`). If any path is outside it, quit and report that before doing anything else. The `mktemp` folder is left in place when you are done; delete it by hand (its path is in `$d`).

Do **not** set `HOME` to anything else.

> **Warning: panes run real programs.** A terminal pane spawns a real CLI agent, and agents use the *real* `~/.agents` install, not the copy. So "new agent end to end", and anything sent from inside a pane, can reach your real teams even though the app itself reads the copy. Do those items **only on a new throwaway team created in this session** (name it `csp-check-tmp`), and delete that team afterwards (in the real install too, if an agent joined it there). Never type into a pane that belongs to a real team.

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
- [ ] **New team** (`csp-check-tmp`) and **new agent** in it, end to end. Throwaway team only (see the warning).
- [ ] **Rename** an agent and a team.
- [ ] **Chat composer** (the user chat box): type, send a message, send a long one, a multi-line one; the message appears in the room.
- [ ] Theme / dark mode switch if the UI has one; logo and avatar images render; fonts look normal.
- [ ] Drag a file onto the window (the window accepts drops); nothing breaks.
- [ ] Leave it running five minutes with a terminal pane producing output; no new console lines.

## 4. Report

Per finding: what you did, what you expected, what happened, the console line (copy it whole), debug or release. "No violations in N minutes of use, all items ticked" is also a result worth sending.

## Appendix: building the binaries yourself

```
cd app && pnpm install --frozen-lockfile && pnpm build              # frontend, embedded into the binary
cd src-tauri
mkdir -p resources/agmsg-core && echo stub > resources/agmsg-core/PLACEHOLDER   # not used in this check
export TAURI_CONFIG='{"identifier":"cc.agmsg.csp-check"}'
cargo build --features tauri/custom-protocol                        # target/debug/agmsg-app
cargo build --release --features tauri/custom-protocol              # target/release/agmsg-app
```
