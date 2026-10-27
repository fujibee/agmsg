#!/bin/bash
# Windows measurement of the PRODUCT build (Git Bash, run inside the logged-in desktop session).
#   usage: run-win.sh <folder holding agmsg-app-win-measure-debug.exe / -release.exe and m1/>  <out-folder>
# Everything goes to files under <out-folder>: one log per step, summary.txt with PASS/FAIL lines
# written as each step ends (a partial run still leaves evidence), and an archive at the end.
# EXPECT_VERIFIED=1 for a build whose WINDOWS_VERIFIED is on (S1 then expects enabled=true).
# Only the executables named above are started and stopped. The installed agmsg app, the real agmsg
# home and agmsgd are not touched: the executables use their own identifier (cc.agmsg.win-measure), a
# throwaway base folder seeded from the bundled scripts (install.sh is never run, HOME is never changed) and
# config/storage/spawn/codex paths inside <out-folder>. A before/after check of the real home fails the run
# if anything the installer or the scripts would write there changed.
set -u
BIN=$(cd "${1:?folder with the executables}" && pwd)
OUT=${2:?out folder}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE="$(cd "$(dirname "$0")" && pwd)"
nat() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
SUM="$OUT/summary.txt"; : > "$SUM"
note() { echo "$(date -u +%FT%TZ) $*" >> "$SUM"; }
verdict() { # verdict PASS|FAIL <step> <text>
  echo "$1 $2 $3" | tee -a "$SUM"
}
session_state() { query session 2>&1 | tr -s ' ' | grep -i "$(whoami | sed 's/.*\\//')" | head -3; }
mark_session() { echo "[$(date -u +%T)] $1: $(session_state | tr '\n' ';')" >> "$OUT/session.log"; }
stop_exe() { taskkill //F //IM "$1" > /dev/null 2>&1; sleep 2; }
trap 'stop_exe agmsg-app-win-measure-debug.exe; stop_exe agmsg-app-win-measure-release.exe; note "run ended (trap)"' EXIT
# ---- isolation: every launch gets these, none of them changes HOME
CORE="$HERE/../core"
export AGMSG_CONFIG="$(nat "$OUT/iso/config.json")" AGMSG_STORAGE_PATH="$(nat "$OUT/iso/storage")" \
  AGMSG_SPAWN_OPTIONS_FILE="$(nat "$OUT/iso/spawn_options.yaml")" CODEX_HOME="$(nat "$OUT/iso/codex-home")"
mkdir -p "$OUT/iso/storage" "$OUT/iso/codex-home"
seed_base() { # seed_base <dir>: lay the bundled scripts out the way an install would, without running the installer
  mkdir -p "$1" && cp -R "$CORE/scripts" "$1/scripts" && cp "$CORE/VERSION" "$CORE/SKILL.md" "$1/" 2>/dev/null; [ -f "$1/scripts/api.sh" ]
}
REAL="$HOME/.agents/skills/agmsg"
snapshot() { # what an install or a script run would change in the real home (live data like messages is left out)
  {
    echo "== real files"; ( cd "$REAL" 2>/dev/null && find scripts SKILL.md VERSION uninstall.sh types templates plugins -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null )
    echo "== real top level"; ls -A "$REAL" 2>/dev/null
    echo "== skills"; ls -A "$HOME/.agents/skills" 2>/dev/null
    echo "== claude commands"; ls -A "$HOME/.claude/commands" 2>/dev/null
    echo "== our team name in the real install"; ls -A "$REAL/teams" "$REAL/db/teams" 2>/dev/null | grep -c "win-measure-tmp"
  } 2>&1
}
snapshot > "$OUT/real-home-before.txt"
[ -d "$CORE/scripts" ] && [ -f "$CORE/scripts/api.sh" ] || { verdict FAIL S0 "the bundled core is missing next to the executables ($CORE)"; exit 3; }


# ---- S0 environment
{
  echo "date: $(date -u +%FT%TZ)"; echo "user: $(whoami)"
  echo "== ver"; cmd //c ver
  echo "== query session"; query session 2>&1
  echo "== WebView2 runtime"; reg query "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" //v pv 2>&1
  echo "== git"; git --version
  echo "== BUILD-INFO"; cat "$BIN/BUILD-INFO.md" 2>&1
  echo "== sha256"; sha256sum "$BIN"/agmsg-app-win-measure-*.exe
  echo "== AV/process check"; tasklist //FI "IMAGENAME eq agmsg-app*" 2>&1
} > "$OUT/s0-env.log" 2>&1
mark_session start
if session_state | grep -qi active; then verdict PASS S0 "an Active desktop session exists for $(whoami)"; else verdict FAIL S0 "no Active session for this user: GUI steps cannot run; stopping"; exit 3; fi

DBG="$BIN/agmsg-app-win-measure-debug.exe"; REL="$BIN/agmsg-app-win-measure-release.exe"
[ -f "$DBG" ] && [ -f "$REL" ] || { verdict FAIL S0 "executables missing in $BIN"; exit 3; }

# launch <exe> <logfile> <seconds-or-0> [env assignments...]: starts the exe, waits, leaves it running when seconds=0
run_for() { # run_for <exe> <log> <seconds> -- env...
  local exe=$1 log=$2 secs=$3; shift 4
  ( env "$@" "$exe" > "$log" 2>&1 < /dev/null & echo $! > "$log.pid" )
  sleep "$secs"
  stop_exe "$(basename "$exe")"
}

# ---- S1 startup check, both profiles, no override: the only reason left must be "not verified"
for prof in debug release; do
  exe=$BIN/agmsg-app-win-measure-$prof.exe
  base=$OUT/base-s1-$prof; seed_base "$base" || { verdict FAIL "S1-$prof" "could not seed the base"; continue; }
  mark_session "S1-$prof before"
  run_for "$exe" "$OUT/s1-$prof.log" 40 -- AGMSG_APP_BASE="$(nat "$base")"
  mark_session "S1-$prof after"
  line=$(grep -F '[addons] startup check:' "$OUT/s1-$prof.log" | tail -1)
  guard=$(grep -c 'frame guard installed' "$OUT/s1-$prof.log")
  if [ "${EXPECT_VERIFIED:-0}" = 1 ]; then want='enabled=true *$'; what="enabled (the build has WINDOWS_VERIFIED on)"; else want='enabled=false add-ons are not verified on WebView2 yet$'; what="only the not-verified reason remains"; fi
  if [ "$guard" -ge 1 ] && echo "$line" | grep -q "$want"; then
    verdict PASS "S1-$prof" "probe passed on the product build ($what); guard installed"
  else
    verdict FAIL "S1-$prof" "startup check line: ${line:-<none>}; guard-installed lines: $guard"
  fi
done

# ---- S2 bootstrap: the throwaway base is seeded from the bundled scripts (no installer), then a throwaway team is joined
BASE=$OUT/base-main; seed_base "$BASE" || verdict FAIL S2 "could not seed the base"; FIX=$OUT/fixture; mkdir -p "$FIX/src"
( cd "$FIX" && git init -q -b main && printf '# E2E project\n\nHello **world**.\n' > README.md && printf 'export const a = 1;\nexport const b = 2;\n' > src/main.ts \
  && printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR' > logo.png && git add -A && git -c user.name=T -c user.email=t@example.com commit -q -m first \
  && printf '# E2E project\n\nHello **there**.\n' > README.md && printf 'untracked file\n' > new.txt ) > "$OUT/s2-fixture.log" 2>&1
TEAM=win-measure-tmp
sed -e "s|__TEAM__|$TEAM|g" -e "s|__FIXTURE__|$(nat "$FIX")|g" "$HERE/bootstrap.js" > "$OUT/bootstrap.js"
mark_session "S2 before"
( AGMSG_APP_BASE="$(nat "$BASE")" AGMSG_ADDON_E2E="$(nat "$OUT/bootstrap.js")" AGMSG_ADDON_E2E_DELAY=8 "$DBG" > "$OUT/s2-bootstrap.log" 2>&1 < /dev/null & )
for _ in $(seq 1 90); do grep -qE '"(FAILED|finished)' "$OUT/s2-bootstrap.log" 2>/dev/null && break; sleep 2; done
stop_exe agmsg-app-win-measure-debug.exe
mark_session "S2 after"
if grep -q '"finished' "$OUT/s2-bootstrap.log"; then verdict PASS S2 "throwaway base seeded from the bundled scripts, team joined"; else verdict FAIL S2 "bootstrap did not finish: $(grep -E 'addons-e2e' "$OUT/s2-bootstrap.log" | tail -2 | tr '\n' ' ')"; fi

# ---- S3 main run (debug build, measuring switch on): panes, reads, the five self-navigations, net probes
sed -e "s|__TEAM__|$TEAM|g" -e "s|__FIXTURE__|$(nat "$FIX")|g" -e "s|__ADDON__|$(nat "$HERE/addon")|g" "$HERE/driver.js" > "$OUT/driver.js"
mark_session "S3 before"
( AGMSG_APP_BASE="$(nat "$BASE")" AGMSG_WINDOWS_MEASURE=1 AGMSG_ADDON_TRACE=1 AGMSG_ADDON_E2E="$(nat "$OUT/driver.js")" AGMSG_ADDON_E2E_DELAY=15 "$DBG" > "$OUT/s3-main.log" 2>&1 < /dev/null & )
for _ in $(seq 1 120); do grep -qE '"(FAILED|finished)' "$OUT/s3-main.log" 2>/dev/null && break; sleep 2; done
sleep 8
mark_session "S3 after"
stop_exe agmsg-app-win-measure-debug.exe
L="$OUT/s3-main.log"
grep -q '"finished' "$L" && verdict PASS S3-driver "the driver finished" || verdict FAIL S3-driver "the driver did not finish: $(grep -E 'addons-e2e.*FAILED' "$L" | head -1 | cut -c1-300)"
grep -q 'ASK FAIL' "$L" && verdict FAIL S3-answers "a direct broker answer was not what was expected" || verdict PASS S3-answers "every direct broker answer as expected"
for need in 'pane=1 gen=1 op=open.args ok' 'pane=1 gen=1 op=fs.stat ok' 'pane=1 gen=1 op=fs.list ok' 'pane=1 gen=1 op=fs.read ok' 'pane=2 gen=1 op=git.diff ok'; do
  grep -q "$need" "$L" && verdict PASS S3-positive "frames made: $need" || verdict FAIL S3-positive "the frames never made: $need"
done
for c in app_tauri app_tauri_localhost_http app_https replace meta_refresh; do
  if ! grep -q "\"k\":\"NAV_case_start\",\"v\":\"$c\"" "$L"; then verdict FAIL "S3-nav-$c" "the case never started"; continue; fi
  if grep -q "\"k\":\"NAV_alive_after_3s\",\"v\":\"$c http://127.0.0.1:" "$L"; then verdict PASS "S3-nav-$c" "the pane was still itself 3 s after the attempt"; else verdict FAIL "S3-nav-$c" "no alive report: the frame may have become the app"; fi
done
grep -c 'cancelled a frame navigation' "$L" | sed 's/^/INFO S3-nav cancelled-frame-navigation lines: /' | tee -a "$SUM"
net() { grep -o "\"k\":\"$1\",\"v\":\"[^\"]*\"" "$L" | head -1 | sed 's/.*"v":"//; s/"$//'; }
w=$(net NET_webrtc_globals); echo "$w" | grep -q 'RTCPeerConnection=undefined webkitRTCPeerConnection=undefined RTCSessionDescription=undefined RTCDataChannel=undefined RTCIceCandidate=undefined' && verdict PASS S3-webrtc-pane "no WebRTC API in the pane" || verdict FAIL S3-webrtc-pane "pane: ${w:-<none>}"
w=$(net NET_webrtc_in_about_blank_child); if [ -z "$w" ]; then w=$(net NET_about_blank_child); fi
if echo "$w" | grep -q 'RTCPeerConnection=undefined webkitRTCPeerConnection=undefined'; then verdict PASS S3-webrtc-child "no WebRTC API in a child frame"
elif echo "$w" | grep -q 'SecurityError'; then verdict PASS S3-webrtc-child "the pane cannot reach into a child frame (opaque origin): $w"
else verdict FAIL S3-webrtc-child "about:blank child: ${w:-<none>}"; fi
w=$(net NET_webrtc_in_srcdoc_child); [ "$w" = "undefined/undefined" ] && verdict PASS S3-webrtc-srcdoc "no WebRTC API in a srcdoc frame" || echo "INFO S3-webrtc-srcdoc srcdoc child: ${w:-<none> (frame refused or no answer)}" | tee -a "$SUM"
w=$(net NET_eval); echo "$w" | grep -q '^blocked' && verdict PASS S3-eval "eval blocked by the pane CSP" || verdict FAIL S3-eval "eval: ${w:-<none>}"
for k in fetch_loopback fetch_lan_like fetch_https; do w=$(net NET_$k); [ "$w" = "failed" ] && verdict PASS "S3-$k" "blocked" || verdict FAIL "S3-$k" "answer: ${w:-<none>}"; done
w=$(net NET_websocket); [ "$w" = "error" ] && verdict PASS S3-websocket "blocked" || verdict FAIL S3-websocket "answer: ${w:-<none>}"
w=$(net NET_image); [ "$w" = "error" ] && verdict PASS S3-image "blocked" || verdict FAIL S3-image "answer: ${w:-<none>}"
w=$(net NET_alive); [ "$w" = "yes" ] && verdict PASS S3-net-finished "the net pane ran to the end" || verdict FAIL S3-net-finished "no end report"

# ---- the real home must be unchanged
snapshot > "$OUT/real-home-after.txt"
if diff "$OUT/real-home-before.txt" "$OUT/real-home-after.txt" > "$OUT/real-home.diff"; then verdict PASS GUARD "the real agmsg home is unchanged (scripts, skills, commands, teams)"; else verdict FAIL GUARD "the real agmsg home changed during the run; see real-home.diff"; fi

# ---- wrap up
mark_session end
stop_exe agmsg-app-win-measure-debug.exe; stop_exe agmsg-app-win-measure-release.exe
rm -rf "$OUT/base-s1-debug" "$OUT/base-s1-release" "$OUT/base-main" "$OUT/fixture"
echo "== counts: $(grep -c '^PASS' "$SUM") PASS, $(grep -c '^FAIL' "$SUM") FAIL" | tee -a "$SUM"
( cd "$(dirname "$OUT")" && tar czf "$OUT.tgz" "$(basename "$OUT")" ) && echo "archive: $OUT.tgz" | tee -a "$SUM"
