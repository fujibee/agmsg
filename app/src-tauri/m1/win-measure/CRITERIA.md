# Setting WINDOWS_VERIFIED = true: pass criteria

`WINDOWS_VERIFIED` (in `src/addons/gate.rs`) turns add-ons on for Windows. It is flipped in one commit, only when every item below holds for the same candidate head. Reviewers check the items against the evidence (CI runs and the returned `summary.txt`); anything not shown counts as not met.

## Evidence required

1. **Windows unit tests.** The `addons-windows` workflow is green at the candidate head (links, hard links, 8.3 names, junctions, case, denylist, real server on Windows paths).
2. **Product build.** The `win-measure` workflow built that same head (the artifact's `BUILD-INFO.md` names the commit and the sha256 of both executables; the run used those hashes).
3. **Run on a real Windows machine** with `run-win.sh`, inside an Active desktop session (`session.log` shows the session Active at the start and end of every step). `summary.txt` has no `FAIL` line and these `PASS` lines:
   - `S0` an Active session exists.
   - `S1-debug` and `S1-release`: the startup check ends with only the "not verified" reason, and the frame guard was installed. That means, on the product build itself: the probe frame is opaque and under the pane CSP, a navigation to the app origin was refused and the refusal was seen as a `frame-src` violation, WebRTC is absent, and the UDP sentinel received nothing.
   - `S2`, `S3-driver`, `S3-answers`, five `S3-positive` lines: the built-in File view and Diff view open, are granted a throwaway folder, and answer every permitted read; every refused request is refused with the expected code.
   - `S3-nav-*` for all five self-navigations (tauri://, http://tauri.localhost, https://tauri.localhost, location.replace, meta refresh): the pane is still itself three seconds after the attempt.
   - `S3-webrtc-pane`, `S3-webrtc-child`, `S3-eval`, `S3-fetch_*` (three), `S3-websocket`, `S3-image`, `S3-net-finished`.
4. **Twice.** Two complete runs, each passing item 3 (a flaky pass is not a pass). Both on a machine whose WebView2 Runtime version is recorded in `s0-env.log`.
5. **Review.** The two reviewers have cleared the candidate head, including `nav_win.rs` (required, fail-closed frame guard) and `no_webrtc.js` plus its wiring in `host.rs`.

## Flip and re-check

6. The flip commit changes only `WINDOWS_VERIFIED` and its comments. A new `win-measure` build of that commit is run once more with `EXPECT_VERIFIED=1`: `S1-debug` and `S1-release` must show `enabled=true`, and the rest still passes.
7. The debug-only measuring switch (`AGMSG_WINDOWS_MEASURE`) stays debug-only: the release executable of the flip commit is the one checked in `S1-release`, and it has no way to waive a reason.

## Not claimed

The run covers the Windows and WebView2 versions of the test machine only. A WebView2 Runtime that cannot supply the frame events fails the guard setup and turns add-ons off by itself (the gate shows why); that behaviour is covered by unit tests, not by the run.
