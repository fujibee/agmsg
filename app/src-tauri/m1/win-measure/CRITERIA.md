# Setting WINDOWS_VERIFIED = true: pass criteria

`WINDOWS_VERIFIED` (in `src/addons/gate.rs`) turns add-ons on for Windows. It is flipped in one commit, only when every item below holds for the same candidate head. Reviewers check the items against the evidence (CI runs and the returned `summary.txt`); anything not shown counts as not met.

## Evidence required

1. **Windows unit tests.** The `addons-windows` workflow is green at the candidate head (links, hard links, 8.3 names, junctions, case, denylist, real server on Windows paths).
2. **Verdict logic.** `selftest.sh` passes in the `win-measure` workflow (it feeds made-up logs to the same functions the run uses: a frame that loaded and said nothing, another step's violation, a report-only violation and a missing record must all FAIL).
3. **Product build.** The `win-measure` workflow built that same head (the artifact's `BUILD-INFO.md` names the commit and the sha256 of both executables; the run used those hashes).
4. **Run on a real Windows machine** with `run-win.sh`, inside an Active desktop session (`session.log` shows the session Active at the start and end of every step). `summary.txt` has no `FAIL` line and these `PASS` lines:
   - `S0` an Active session exists; `GUARD` the real agmsg home (scripts, skills, commands, teams) is byte-for-byte unchanged by the run (the run never runs install.sh and never changes HOME).
   - `S1-debug` and `S1-release`: the startup check ends with only the "not verified" reason, and the frame guard was installed. That means, on the product build itself: the probe frame is opaque and under the pane CSP, a navigation to the app origin was refused and the refusal was seen as a `frame-src` violation, WebRTC is absent, and the UDP sentinel received nothing.
   - `S2`, `S3-driver`, `S3-answers`, five `S3-positive` lines: the built-in File view and Diff view open, are granted a throwaway folder, and answer every permitted read; every refused request is refused with the expected code.
   - `S3-nav-*` for all five self-navigations (tauri://, http://tauri.localhost, https://tauri.localhost, location.replace, meta refresh): the pane is still itself three seconds after the attempt.
   - WebRTC, in every realm a pane can reach: `S3-realm-*` for the first script of the pane page (before anything else ran), the pane page, a srcdoc child, a nested child, an about:blank child, a blob: child, a data: child, a dedicated worker and a shared worker. Each passes only if a script ran there and found no WebRTC name, or if the evidence shows no script can run there (the frame never loaded and the app logged the refused navigation; an enforced `frame-src`/`worker-src`/`script-src` report; a worker that failed to start; an unreachable about:blank document). A realm that loaded and said nothing, or that exposes any WebRTC name, fails. `S3-sink-hits`: a local UDP+TCP sink received nothing from the panes (`S3-sink-control` proves the sink counts).
   - Egress: `S3-csp-report` (enforced CSP reports with directive and blocked address for the LAN-like and public addresses), `S3-egress-*` (nothing went through; the loopback attempts at the sink are covered by `S3-sink-hits`), `S3-eval`, `S3-net-finished`.
   - `S1-release-switch`: the release build with `AGMSG_WINDOWS_MEASURE=1` still reports the not-verified reason (the measuring switch is compiled out).
5. **Twice.** Two complete runs, each passing item 4 (a flaky pass is not a pass). Both on a machine whose WebView2 Runtime version is recorded in `s0-env.log`.
6. **Review.** The two reviewers have cleared the candidate head, including `nav_win.rs` (required, fail-closed frame guard) and `no_webrtc.js` plus its wiring in `host.rs`.

## Flip and re-check

7. The flip commit changes only `WINDOWS_VERIFIED` and its comments. A new `win-measure` build of that commit is run once more with `EXPECT_VERIFIED=1`: `S1-debug` and `S1-release` must show `enabled=true`, and the rest still passes.
8. The debug-only measuring switch (`AGMSG_WINDOWS_MEASURE`) stays debug-only: after the flip, `S1-release-switch` is kept as a check that the switch has no effect in the release build (the not-verified reason cannot come back, and nothing else can be waived).

## Not claimed

The run covers the Windows and WebView2 versions of the test machine only. A WebView2 Runtime that cannot supply the frame events fails the guard setup and turns add-ons off by itself (the gate shows why); that behaviour is covered by unit tests, not by the run.
