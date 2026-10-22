# M1 on Windows (WebView2) — run request

Prebuilt binaries: no Rust, Node or pnpm is needed on the test machine. CI (`.github/workflows/m1-windows.yml`, push to branch `addon-m1`) builds every variant, debug and release, with the frontend embedded, and uploads one artifact `m1-windows` (executables in `bin/`, the scripts and fixtures in `m1/`, `BUILD-INFO.md`).
Everything below runs in **Git Bash** from the artifact folder. Results: copy back the whole log directory (`$M1_RUN`, below) plus the answers to the numbered questions.
Do not use or touch the installed agmsg app, `~/.agents/skills/agmsg`, or any real config. The executables use their own identifier (`cc.agmsg.m1spike`) and a throwaway `AGMSG_APP_BASE` inside `$M1_RUN`.

## 0. Fetch and set up
```
gh run download <run-id> -R fujibee/agmsg -n m1-windows -D m1-windows     # or unzip the zip you were handed
cd m1-windows
export M1_PREBUILT="$PWD/bin"           # the prebuilt executables; nothing is built
export M1_RUN="$HOME/m1run"             # logs go here
export M1_LAN_IP=<this machine's LAN IPv4>     # the LAN sentinel; run `ipconfig` to find it
```
Executables: `agmsg-app-<variant>-<profile>.exe` with variant `none`, `acl`, `remote`, or `aclcsp` (= `acl` plus the main-window CSP from `m1/main-csp.txt`, which the CSP rows need), profile `debug` or `release`.
In the commands below, `m1/run.sh <variant> <profile> <logname> [seconds]` launches one executable, prints its log and stops only that process. Setting `M1_MAIN_CSP=1` makes the scripts pick the `aclcsp` executable.

Record first: Windows version/build; WebView2 Runtime version (`reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" /v pv`); `BUILD-INFO.md` (rustc, tauri/wry/webview2-com versions, commit).
AV note: McAfee/Defender are active on this machine; if a run is killed or blue-screens, say so and which driver. If a process survives a script, stop it with `taskkill /F /IM agmsg-app-<variant>-<profile>.exe`.
Run every row for **debug and release**.

## A1 — ACL alone (key handed to the frame)
```
M1_ENTRY=index.html m1/run.sh acl debug a1-acl-debug 14        # and release
```
Expected: `CANARY ENTERED` appears once (`from-main-ui`) and never for `A1-*`.
Also report from the log: the `globals` line (is `window.ipc` / `chrome.webview` / `__TAURI_INTERNALS__` present in the frame?), `A1_ipc_scheme`, `A1_http_ipc.localhost`, `A1_https_ipc.localhost`, `A1_channel_fetch_0_119` and the `ua` line.

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
`a1.js` sweeps `plugin:__TAURI_CHANNEL__|fetch` for ids 0..119 while the main UI runs a live Channel feed (`CHANNEL FEED started` in the log). Report `A1_channel_fetch_0_119`: `data` must be 0. Any `data > 0` is a FAIL: report immediately, do not look for a fix.

## C — navigation: native handler alone, then with the main-window CSP
```
m1/nav-all.sh acl debug navA                    # all 22 cases; logs navA-<case>.log
export M1_MAIN_CSP=1                            # picks the aclcsp executables
m1/nav-subset.sh acl debug navB app_tauri app_tauri_localhost_http app_https replace meta_refresh
unset M1_MAIN_CSP
```
The CSP baked into `aclcsp` allows `frame-src http://127.0.0.1:*` only, so the frame must not be able to load the app origin (`http(s)://tauri.localhost`).
Key question: in `navB`, does any of the 5 self-navigation variants make the frame become the app origin (a `NAV https://tauri.localhost/ -> allow` line for the frame, the pane page no longer reporting `NAV_still_alive_after_2s`, or the app UI appearing inside the frame)? If yes on Windows that is a FAIL (bridge and key are injected into subframes there): report it first.
Also record, for `navA`, whether the `on_navigation` handler logs subframe navigations (`NAV ...` lines for `ext_https`, `other_loopback`, `lan`).

## C — egress and fetched code (pane CSP), one launch per group
```
m1/c-all.sh acl debug cwin        # 12 launches; logs cwin-net{0,1}-<group>.log
```
Report per log: sentinel hits (`SENTINEL S1/S2/LAN/UDP`), `RAN_` lines (none expected), `C_webrtc_globals`, and anything differing from: net0 → zero hits except the report port; net1 → hits only on S2 for fetch/xhr/sse/beacon/img/font/audio.

## WebRTC setting (find the WebView2 equivalent)
Positive control: `M1_ENTRY="c.html#webrtc" m1/run.sh acl debug cwin-webrtc-base 11` (expect UDP hits on the sentinel).
Then try each candidate until `RTCPeerConnection` is absent or UDP hits are 0, one launch each:
```
M1_WV2_ARGS="--disable-webrtc"                                           M1_ENTRY="c.html#webrtc" m1/run.sh acl debug cwin-webrtc-a1 11
M1_WV2_ARGS="--force-webrtc-ip-handling-policy=disable_non_proxied_udp"  M1_ENTRY="c.html#webrtc" m1/run.sh acl debug cwin-webrtc-a2 11
M1_WV2_ARGS="--disable-features=WebRtcHideLocalIpsWithMdns,WebRTC"        M1_ENTRY="c.html#webrtc" m1/run.sh acl debug cwin-webrtc-a3 11
```
(`M1_WV2_ARGS` replaces Tauri's default WebView2 browser arguments; also state if a candidate breaks the app UI itself.) A browser policy / registry route is welcome if the arguments do not work. Report the args, the globals line and the UDP hit count.

## D — pane server
```
m1/d.sh acl debug dwin
```
Report `$M1_RUN/dwin.txt`. Windows-specific interest: `backslash*`, `drive_letter*`, `unc`, `hardlink_to_outside`, `symlink_*` (Git Bash `ln -s` makes copies unless `MSYS=winsymlinks:nativestrict` and developer mode are on; if symlinks cannot be created, say so and try a directory junction with `mklink /J`).

## G — positive render (second round)
The adapted agmsg-office build is provided separately. Then:
```
M1_PAYLOAD="$(cygpath -m <path to office-web>)" M1_CSP="$(m1/csp.sh)" M1_ENTRY=index.html m1/run.sh acl debug gwin 14
```
Expect `G_dom ... imgs_loaded=2` and `G_violations=0`.

## Release builds
Repeat A1, A2, the navB subset, c-all and d.sh with `release` (use a `-rel` suffix in the log names).
