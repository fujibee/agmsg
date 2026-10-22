# M1 on Windows (WebView2) — run request

Branch: `addon-m1` of `fujibee/agmsg` (spike harness, not for merge). Everything below runs from `app/src-tauri` in **Git Bash**.
Results: copy the whole `C:\...\m1run` log directory (or `/tmp/m1run` in Git Bash) back, plus the answers to the numbered questions.
Do not use or touch the installed agmsg app, `~/.agents/skills/agmsg`, or any real config. The harness uses its own app identifier (`cc.agmsg.m1spike`) and a throwaway `AGMSG_APP_BASE`.

## 0. Prepare
```
git fetch origin addon-m1 && git checkout addon-m1
cd app && pnpm install --frozen-lockfile && node_modules/.bin/vite build && cd src-tauri
mkdir -p resources/agmsg-core && echo spike > resources/agmsg-core/PLACEHOLDER
mkdir -p /tmp/m1run
```
Record: Windows version/build, WebView2 Runtime version (`reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" /v pv`), `rustc --version`, tauri/wry/webview2-com versions from `Cargo.lock`.
AV note: McAfee/Defender are active on this machine; if a run is killed or blue-screens, say so and which driver.

`m1/run.sh <variant> <debug|release> <logname> [seconds]` builds and runs one launch and prints `/tmp/m1run/<logname>.log`.
If the app process survives after the script ends, stop it with `taskkill /IM agmsg-app.exe /F` (only this process — it is the spike build).
Set `M1_LAN_IP=<this machine's LAN IPv4>` for every run (the LAN sentinel).
Run every row for **debug and release**.

## A1 — ACL alone (key handed to the frame)
```
M1_ENTRY=index.html m1/run.sh acl debug a1-acl-debug 14        # and release
```
Expected: `CANARY ENTERED` appears once (`from-main-ui`) and never for `A1-*`.
Also report from the log: `globals` line (is `window.ipc` / `chrome.webview` / `__TAURI_INTERNALS__` present in the frame?), `A1_ipc_scheme`, `A1_http_ipc.localhost`, `A1_https_ipc.localhost`, `A1_channel_fetch_0_119` and the `ua` line.

## A1 control — ACL allows the loopback origin
```
M1_ENTRY=index.html m1/run.sh remote debug a1-remote-debug 14
```
Expected: `CANARY ENTERED arg=A1-...` appears (proves the probe can see an entry).

## A2 — ACL open, key not handed
```
M1_NOKEY=1 M1_ENTRY=a2.html m1/run.sh remote debug a2-nokey-debug 14
```
Expected: no `A1-*`/`A2-*` canary entry. Report every `A2_*` line (especially `A2_own_globals`: does the frame already hold a bridge/key on Windows?).

## Channel fetch
`a1.js` already sweeps `plugin:__TAURI_CHANNEL__|fetch` for ids 0..119 while the main UI runs a live Channel feed (`CHANNEL FEED started` in the log). Report `A1_channel_fetch_0_119`: `data` must be 0. Any `data > 0` is a FAIL: report immediately, do not look for a fix.

## C — navigation (no main-window CSP) and with the main-window CSP
```
m1/nav-all.sh acl debug navA      # all 22 cases; logs navA-<case>.log
```

Note: on Windows the app origin is `http(s)://tauri.localhost`, so for the second run set the CSP **without** the two `tauri.localhost` entries in `frame-src` (`frame-src http://127.0.0.1:*` only) — that is the CSP under test:
```
export M1_MAIN_CSP="default-src 'self' tauri: ipc: http://ipc.localhost https://ipc.localhost http://tauri.localhost https://tauri.localhost; script-src 'self' http://tauri.localhost https://tauri.localhost; style-src 'self' 'unsafe-inline' http://tauri.localhost https://tauri.localhost; img-src 'self' data: blob: http://tauri.localhost https://tauri.localhost; font-src 'self' data: http://tauri.localhost https://tauri.localhost; connect-src ipc: http://ipc.localhost https://ipc.localhost tauri: http://tauri.localhost https://tauri.localhost; frame-src http://127.0.0.1:*"
m1/nav-subset.sh acl debug navB app_tauri app_tauri_localhost_http app_https replace meta_refresh
```
Key question: with this CSP, does any of the 5 self-navigation variants make the frame become the app origin (a `NAV https://tauri.localhost/ -> allow` line **for the frame**, the pane page no longer reporting `NAV_still_alive_after_2s`, or the app UI appearing inside the frame)? If yes on Windows that is a FAIL (bridge and key are injected into subframes there): report it first.
Also record, for `navA`, whether the `on_navigation` handler logs subframe navigations (`NAV ...` lines for `ext_https`, `other_loopback`, `lan`).

## C — egress and fetched code (CSP of §4.4), one launch per group
```
m1/c-all.sh acl debug cwin        # 12 launches; logs cwin-net{0,1}-<group>.log
```
Report per log: sentinel hits (`SENTINEL S1/S2/LAN/UDP`), `RAN_` lines (none expected), `C_webrtc_globals`, and anything differing from: net0 → zero hits except the report port; net1 → hits only on S2 for fetch/xhr/sse/beacon/img/font/audio.

## WebRTC setting (find the WebView2 equivalent)
First the positive control: `M1_ENTRY="c.html#webrtc" m1/run.sh acl debug cwin-webrtc-base 11` (expect UDP hits on the sentinel).
Then try each candidate until RTCPeerConnection is absent or UDP hits are 0, one launch each:
```
M1_WV2_ARGS="--disable-webrtc" ...
M1_WV2_ARGS="--force-webrtc-ip-handling-policy=disable_non_proxied_udp" ...
M1_WV2_ARGS="--disable-features=WebRtcHideLocalIpsWithMdns,WebRTC" ...
```
(`M1_WV2_ARGS` replaces Tauri's default WebView2 browser arguments; also state if a candidate breaks the app UI itself.) A browser policy / registry route is welcome if the arguments do not work. Report the args, the globals line and the UDP hit count.

## D — pane server
```
m1/d.sh acl debug dwin
```
Report `/tmp/m1run/dwin.txt`. Windows-specific interest: `backslash*`, `drive_letter*`, `unc`, `hardlink_to_outside`, `symlink_*` (creating symlinks needs developer mode/admin; if not possible, say so and try a directory junction: `mklink /J`).

## G — positive render
The adapted agmsg-office build is not in the repo (29 MB); it is provided separately. Then:
```
M1_PAYLOAD=<path to office-web> M1_CSP="$(m1/csp.sh)" M1_ENTRY=index.html m1/run.sh acl debug gwin 14
```
Expect `G_dom ... imgs_loaded=2` and `G_violations=0`.

## Release builds
Repeat A1, A2, the navB subset, c-all and d.sh with `release` (use a `-rel` suffix in the log names).
