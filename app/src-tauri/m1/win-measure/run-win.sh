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
[ ! -e "$OUT" ] || { echo "out folder $OUT already exists; give a new name" >&2; exit 2; }
mkdir "$OUT" || exit 2; OUT=$(cd "$OUT" && pwd)
HERE="$(cd "$(dirname "$0")" && pwd)"
nat() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
SUM="$OUT/summary.txt"; : > "$SUM"
TRACK="$OUT/pids.txt"; : > "$TRACK"
. "$HERE/procs.sh"
# ---- preflight: nothing is launched and no trap is set until this passes
if other_run_present; then echo "FAIL S0 an agmsg-app-win-measure-*.exe is already running (another run?); nothing was started or stopped" | tee -a "$SUM"; exit 3; fi
note() { echo "$(date -u +%FT%TZ) $*" >> "$SUM"; }
verdict() { # verdict PASS|FAIL <step> <text>
  echo "$1 $2 $3" | tee -a "$SUM"
}
session_state() { query session 2>&1 | tr -s ' ' | grep -i "$(whoami | sed 's/.*\\//')" | head -3; }
mark_session() { echo "[$(date -u +%T)] $1: $(session_state | tr '\n' ';')" >> "$OUT/session.log"; }
. "$HERE/sink.sh"
. "$HERE/archive.sh"
# end_run: the one way every run ends, normal or early, once: stop what this run started, say so, then the
# real-home guard, the counts and the archive (the archive line is written BEFORE the archive is made, so the
# summary inside the archive is the same as the one in the output folder and ends with it)
ENDED=0
end_run() {
  [ "$ENDED" = 0 ] || return 0
  ENDED=1
  stop_sink; stop_launched; note "run ended"
  snapshot > "$OUT/real-home-after.txt"
  if diff "$OUT/real-home-before.txt" "$OUT/real-home-after.txt" > "$OUT/real-home.diff"; then verdict PASS GUARD "the real agmsg home is unchanged (scripts, skills, commands, teams)"; else verdict FAIL GUARD "the real agmsg home changed during the run; see real-home.diff"; fi
  echo "== counts: $(grep -c '^PASS' "$SUM") PASS, $(grep -c '^FAIL' "$SUM") FAIL" | tee -a "$SUM"
  echo "archive: $OUT.tgz" | tee -a "$SUM"
  make_archive
}
trap end_run EXIT
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
  echo "== BUILD-INFO"; cat "$(dirname "$BIN")/BUILD-INFO.md" 2>&1
  echo "== sha256"; sha256sum "$BIN"/agmsg-app-win-measure-*.exe
  echo "== builtin-addons (name size mode type, then sha256): compare with the digests pinned in the exe"
  if [ -d "$BIN/builtin-addons" ]; then ( cd "$BIN/builtin-addons" || exit 1; find . -printf '%p %s %m %y\n' | sort; find . -type f | sort | xargs sha256sum ) 2>&1; else echo "missing: $BIN/builtin-addons"; fi
  echo "== AV/process check"; tasklist //FI "IMAGENAME eq agmsg-app*" 2>&1
} > "$OUT/s0-env.log" 2>&1
mark_session start
if session_state | grep -qi active; then verdict PASS S0 "an Active desktop session exists for $(whoami)"; else verdict FAIL S0 "no Active session for this user: GUI steps cannot run; stopping"; exit 3; fi

DBG="$BIN/agmsg-app-win-measure-debug.exe"; REL="$BIN/agmsg-app-win-measure-release.exe"
[ -f "$DBG" ] && [ -f "$REL" ] || { verdict FAIL S0 "executables missing in $BIN"; exit 3; }
# macOS AppleDouble files (._name) from a tar made on a Mac: Windows extracts them as real files and a digest then counts them
stray=$(find "$BIN" "$HERE" -name '._*' 2>/dev/null | head -5 | tr '\n' ' ')
[ -z "$stray" ] || { verdict FAIL S0 "stray macOS metadata files in the package (._*): $stray; the archive was made without COPYFILE_DISABLE=1"; exit 3; }
# the built-in add-ons are resources the app looks for next to its exe (a plain build is not bundled)
[ -d "$BIN/builtin-addons/fileview" ] && [ -d "$BIN/builtin-addons/diffview" ] || { verdict FAIL S0 "builtin-addons/ is missing next to the executables in $BIN: File view and Diff view cannot open"; exit 3; }

# launch <exe> <logfile> <seconds-or-0> [env assignments...]: starts the exe, waits, leaves it running when seconds=0
# A process that cannot be started under its real Windows id, or survives its stop, ends the run:
# the next step would otherwise run next to it (single instance) and every later result would be noise.
stop_or_abort() { stop_launched 2>>"$OUT/procs.err" || { verdict FAIL "$1" "a process of this step could not be stopped (procs.err); not going on"; exit 3; }; }
launch_or_abort() { local step=$1; shift; launch "$@" 2>>"$OUT/procs.err" || { verdict FAIL "$step" "could not find the Windows id of the process just started (procs.err); not going on"; exit 3; }; }
run_for() { # run_for <step> <exe> <log> <max seconds> -- env...: ends 3 s after the startup check has reported, or at the maximum
  local step=$1 exe=$2 log=$3 secs=$4 waited=0; shift 5
  launch_or_abort "$step" "$log" "$exe" "$@"
  while [ "$waited" -lt "$secs" ]; do
    if grep -q '\[addons\] startup check:' "$log" 2>/dev/null; then sleep 3; break; fi
    sleep 1; waited=$((waited + 1))
  done
  stop_or_abort "$step"
}

# ---- S1 startup check, both profiles, no override: the only reason left must be "not verified"
for prof in debug release; do
  exe=$BIN/agmsg-app-win-measure-$prof.exe
  base=$OUT/base-s1-$prof; seed_base "$base" || { verdict FAIL "S1-$prof" "could not seed the base"; continue; }
  mark_session "S1-$prof before"
  run_for "S1-$prof" "$exe" "$OUT/s1-$prof.log" 70 -- AGMSG_APP_BASE="$(nat "$base")"
  mark_session "S1-$prof after"
  line=$(grep -F '[addons] startup check:' "$OUT/s1-$prof.log" | tail -1)
  guard=$(grep -c 'frame guard installed' "$OUT/s1-$prof.log")
  if grep -q '\[addons\] add-ons: builtin:diffview(ok) builtin:fileview(ok)' "$OUT/s1-$prof.log"; then verdict PASS "S1-$prof-builtins" "both built-in add-ons were found and match their digests"; else verdict FAIL "S1-$prof-builtins" "built-in add-ons: $(grep -F '[addons] add-ons:' "$OUT/s1-$prof.log" | head -1)"; fi
  if [ "${EXPECT_VERIFIED:-0}" = 1 ]; then want='enabled=true *$'; what="enabled (the build has WINDOWS_VERIFIED on)"; else want='enabled=false add-ons are not verified on WebView2 yet$'; what="only the not-verified reason remains"; fi
  if [ "$guard" -ge 1 ] && echo "$line" | grep -q "$want"; then
    verdict PASS "S1-$prof" "probe passed on the product build ($what); guard installed"
  else
    verdict FAIL "S1-$prof" "startup check line: ${line:-<none>}; guard-installed lines: $guard"
  fi
done

# ---- S1b: the measuring switch must do nothing in the release build
base=$OUT/base-s1-release-switch; seed_base "$base" || verdict FAIL S1-release-switch "could not seed the base"
mark_session "S1b before"
run_for S1-release-switch "$REL" "$OUT/s1-release-switch.log" 70 -- AGMSG_APP_BASE="$(nat "$base")" AGMSG_WINDOWS_MEASURE=1
mark_session "S1b after"
line=$(grep -F '[addons] startup check:' "$OUT/s1-release-switch.log" | tail -1)
if [ "${EXPECT_VERIFIED:-0}" = 1 ]; then want='enabled=true *$'; else want='enabled=false add-ons are not verified on WebView2 yet$'; fi
if echo "$line" | grep -q "$want"; then verdict PASS S1-release-switch "AGMSG_WINDOWS_MEASURE=1 changes nothing in the release build"; else verdict FAIL S1-release-switch "with the switch set the release build reported: ${line:-<none>}"; fi

# ---- S2 bootstrap: the throwaway base is seeded from the bundled scripts (no installer), then a throwaway team is joined
BASE=$OUT/base-main; seed_base "$BASE" || verdict FAIL S2 "could not seed the base"; FIX=$OUT/fixture; mkdir -p "$FIX/src"
( cd "$FIX" && git init -q -b main && printf '# E2E project\n\nHello **world**.\n' > README.md && printf 'export const a = 1;\nexport const b = 2;\n' > src/main.ts \
  && printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR' > logo.png && git add -A && git -c user.name=T -c user.email=t@example.com commit -q -m first \
  && printf '# E2E project\n\nHello **there**.\n' > README.md && printf 'untracked file\n' > new.txt ) > "$OUT/s2-fixture.log" 2>&1
TEAM=win-measure-tmp
sed -e "s|__TEAM__|$TEAM|g" -e "s|__FIXTURE__|$(nat "$FIX")|g" "$HERE/bootstrap.js" > "$OUT/bootstrap.js"
mark_session "S2 before"
launch_or_abort S2 "$OUT/s2-bootstrap.log" "$DBG" AGMSG_APP_BASE="$(nat "$BASE")" AGMSG_ADDON_E2E="$(nat "$OUT/bootstrap.js")" AGMSG_ADDON_E2E_DELAY=8
for _ in $(seq 1 90); do grep -qE '"(FAILED|finished)' "$OUT/s2-bootstrap.log" 2>/dev/null && break; sleep 2; done
stop_or_abort S2
mark_session "S2 after"
if grep -q '"finished' "$OUT/s2-bootstrap.log"; then verdict PASS S2 "throwaway base seeded from the bundled scripts, team joined"; else verdict FAIL S2 "bootstrap did not finish: $(grep -E 'addons-e2e' "$OUT/s2-bootstrap.log" | tail -2 | tr '\n' ' ')"; fi

# ---- S3 main run (debug build, measuring switch on): panes, reads, the five self-navigations, net probes
sed -e "s|__TEAM__|$TEAM|g" -e "s|__FIXTURE__|$(nat "$FIX")|g" -e "s|__ADDON__|$(nat "$HERE/addon")|g" "$HERE/driver.js" > "$OUT/driver.js"
SINK="$OUT/sink-hits.txt"; SINKN=$(nat "$SINK")
( powershell -NoProfile -ExecutionPolicy Bypass -File "$(nat "$HERE/sink.ps1")" -Port 47931 -Seconds 900 -Out "$SINKN" > "$OUT/sink.log" 2>&1 & )
SINK_TOKEN="$$-$(date +%s)-$RANDOM"; SINK_STOPPED=0
for _ in $(seq 1 20); do case "$(sink_val)" in udp=*|ERROR*) break ;; esac; sleep 0.5; done
v=$(sink_val)
case "$v" in
  udp=*) verdict PASS S3-sink-start "the sink is listening on 127.0.0.1:47931" ;;
  *) verdict FAIL S3-sink-start "the sink did not report a count (${v:-no output}); sink.log: $(tr -d '\r' < "$OUT/sink.log" 2>/dev/null | tail -2 | tr '\n' ' ')"
     stop_sink; exit 4 ;;
esac
powershell -NoProfile -Command '$c=New-Object System.Net.Sockets.UdpClient; [void]$c.Send([byte[]](1,2,3),3,"127.0.0.1",47931); $c.Close(); $t=New-Object System.Net.Sockets.TcpClient("127.0.0.1",47931); $t.Close()' > "$OUT/sink-control.log" 2>&1
sleep 2
if [ "$(sink_val)" = "udp=1 tcp=1" ]; then verdict PASS S3-sink-control "the UDP/TCP sink saw the control packet and connection"; else verdict FAIL S3-sink-control "the sink did not see its control traffic: $(sink_val)"; fi
mark_session "S3 before"
launch_or_abort S3 "$OUT/s3-main.log" "$DBG" AGMSG_APP_BASE="$(nat "$BASE")" AGMSG_WINDOWS_MEASURE=1 AGMSG_ADDON_TRACE=1 AGMSG_ADDON_E2E="$(nat "$OUT/driver.js")" AGMSG_ADDON_E2E_DELAY=15
for _ in $(seq 1 180); do grep -qE '"(FAILED|finished)' "$OUT/s3-main.log" 2>/dev/null && break; sleep 2; done
sleep 8
mark_session "S3 after"
stop_or_abort S3
# the evaluation reads a copy without carriage returns (Windows tools may add them)
tr -d '\r' < "$OUT/s3-main.log" > "$OUT/s3-main.clean.log"; L="$OUT/s3-main.clean.log"
grep -q '"finished' "$L" && verdict PASS S3-driver "the driver finished" || verdict FAIL S3-driver "the driver did not finish: $(grep -E 'addons-e2e.*FAILED' "$L" | head -1 | cut -c1-300)"
grep -q 'ASK FAIL' "$L" && verdict FAIL S3-answers "a direct broker answer was not what was expected" || verdict PASS S3-answers "every direct broker answer as expected"
for need in 'pane=1 gen=1 op=open.args ok' 'pane=1 gen=1 op=fs.stat ok' 'pane=1 gen=1 op=fs.list ok' 'pane=1 gen=1 op=fs.read ok' 'pane=2 gen=1 op=git.diff ok'; do
  grep -q "$need" "$L" && verdict PASS S3-positive "frames made: $need" || verdict FAIL S3-positive "the frames never made: $need"
done
. "$HERE/evaluate.sh"
for c in app_tauri app_tauri_localhost_http app_https replace meta_refresh; do eval_nav "$c"; done
grep -c 'cancelled a frame navigation' "$L" | sed 's/^/INFO S3-nav cancelled-frame-navigation lines: /' | tee -a "$SUM"
eval_net 2>&1 | while IFS= read -r line; do case "$line" in INFO*) echo "$line" | tee -a "$SUM" ;; *) echo "$line" ;; esac; done
stop_sink
sink_verdict

# ---- S4 agent powers on the real window path (debug build, measuring switch): the pane asks the broker, the app
# opens a real terminal pane for the spawned agent. The agent CLI is a stand-in (stubs/claude.cmd) found first on PATH.
STUBS=$OUT/stubs; mkdir -p "$STUBS"; cp "$HERE/stubs/claude.cmd" "$STUBS/claude.cmd"
sed -e "s|__TEAM__|$TEAM|g" -e "s|__ADDON__|$(nat "$HERE/addon")|g" "$HERE/driver-powers.js" > "$OUT/driver-powers.js"
mark_session "S4 before"
launch_or_abort S4 "$OUT/s4-powers.log" "$DBG" AGMSG_APP_BASE="$(nat "$BASE")" AGMSG_WINDOWS_MEASURE=1 AGMSG_ADDON_TRACE=1 AGMSG_ADDON_E2E="$(nat "$OUT/driver-powers.js")" AGMSG_ADDON_E2E_DELAY=15 PATH="$STUBS:$PATH"
for _ in $(seq 1 120); do grep -qE '"(FAILED|finished)' "$OUT/s4-powers.log" 2>/dev/null && break; sleep 2; done
mark_session "S4 after"
tr -d '\r' < "$OUT/s4-powers.log" > "$OUT/s4-powers.clean.log"; P="$OUT/s4-powers.clean.log"
grep -q '"finished' "$P" && verdict PASS S4-driver "the powers driver finished" || verdict FAIL S4-driver "the powers driver did not finish: $(grep -E 'addons-e2e.*FAILED' "$P" | head -1 | cut -c1-300)"
grep 'POW \(PASS\|FAIL\)' "$P" | sed -e 's/.*POW PASS /PASS S4-powers /' -e 's/.*POW FAIL /FAIL S4-powers /' | tee -a "$SUM"
grep -q 'POW \(PASS\|FAIL\)' "$P" || verdict FAIL S4-powers "the driver reported no result lines"

# ---- S5 (M-5 on Windows): kill the app with the agent running; does the agent CLI outlive it, and what does the next start say?
AGENT=$(sed -n 's/.*POW SPAWNED pid=\([0-9]*\).*/\1/p' "$P" | head -1)
APPPID=$(tail -1 "$TRACK" | cut -d' ' -f1)
if [ -n "$AGENT" ] && [ "$(image_of "$AGENT")" != "" ]; then
  KIDS=$(powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"ParentProcessId=$AGENT\" | Select-Object -ExpandProperty ProcessId" 2>/dev/null | tr -d '\r')
  echo "$AGENT $(image_of "$AGENT")" >> "$TRACK"
  for k in $KIDS; do echo "$k $(image_of "$k")" >> "$TRACK"; done   # so the end of the run stops any leftover, by id and image
  echo "S5: agent pid $AGENT image $(image_of "$AGENT") children: ${KIDS:-none}; app pid $APPPID" >> "$OUT/s5.log"
  cp "$BASE/addons/agents-journal.json" "$OUT/s5-journal-before-kill.json" 2>/dev/null
  taskkill //F //PID "$APPPID" >> "$OUT/s5.log" 2>&1
  sleep 4
  survivors=""; for p in $AGENT $KIDS; do [ -n "$(image_of "$p")" ] && survivors="$survivors $p"; done
  cp "$BASE/addons/agents-journal.json" "$OUT/s5-journal-after-kill.json" 2>/dev/null
  if [ -n "$survivors" ]; then expect_state=orphaned; verdict PASS S5-child "after the app was killed the agent process(es) survive:$survivors (so a terminal child can outlive the app; opening stays unknown after a restart)"
  else expect_state=joined; verdict PASS S5-child "after the app was killed no agent process was left (the child died with the app)"; fi
  # restart: recovery settles the journal
  mark_session "S5 restart before"
  launch_or_abort S5 "$OUT/s5-restart.log" "$DBG" AGMSG_APP_BASE="$(nat "$BASE")" AGMSG_WINDOWS_MEASURE=1 PATH="$STUBS:$PATH"
  for _ in $(seq 1 60); do grep -q '\[addons\] startup check:' "$OUT/s5-restart.log" 2>/dev/null && break; sleep 1; done
  sleep 8
  cp "$BASE/addons/agents-journal.json" "$OUT/s5-journal-after-restart.json" 2>/dev/null
  mark_session "S5 restart after"
  st=$(tr -d '\r' < "$OUT/s5-journal-after-restart.json" 2>/dev/null | grep -A12 '"requested": "white"' | sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' | head -1)
  if [ "$st" = "$expect_state" ]; then verdict PASS S5-recovery "after the restart the agent entry is $st, as it should be (survivors:${survivors:- none})"; else verdict FAIL S5-recovery "after the restart the agent entry is '${st:-<none>}', expected $expect_state (survivors:${survivors:- none})"; fi
  stop_or_abort S5
else
  verdict FAIL S5 "no agent process to test (S4 did not spawn one; pid '${AGENT:-none}')"
  stop_or_abort S4
fi

# ---- S6 how long the bundled scripts take on this machine (the broker's ops are these scripts): a bare bash, api.sh,
# send.sh and join.sh, 5 runs each from the same Git Bash, with the number of external programs each starts
# (counted from an xtrace of one run: command words that resolve to files; subshell forks of $(...) are not in it)
ms_now() { date +%s%3N; }
forks_of() { env SHELLOPTS=xtrace PS4='+X ' bash "$@" 2>&1 >/dev/null | sed -n 's/^+*X \([^ ]*\).*/\1/p' | while read -r w; do [ "$(type -t "$w" 2>/dev/null)" = file ] && echo "$w"; done | wc -l | tr -d ' '; }
s6() { # s6 <label> <runs> -- command...
  local label=$1 runs=$2; shift 3; local i t0 t1 all=""
  for i in $(seq 1 "$runs"); do t0=$(ms_now); "$@" > /dev/null 2>&1; t1=$(ms_now); all="$all $((t1 - t0))"; done
  echo "$label ms:$all" | tee -a "$OUT/s6.log"
}
mark_session "S6 before"
(
  export AGMSG_APP_BASE="$(nat "$BASE")"
  SC="$BASE/scripts"
  s6 "bash -c true" 5 -- bash -c true
  s6 "api.sh get teams $TEAM members" 5 -- bash "$SC/api.sh" get teams "$TEAM" members
  s6 "send.sh" 5 -- bash "$SC/send.sh" "$TEAM" tester powers-measure "s6 timing"
  n=0; s6 "join.sh" 5 -- bash -c 'n=$((RANDOM)); bash "$0" "$1" "s6-$n" agmsg-app "$2"' "$SC/join.sh" "$TEAM" "$(nat "$FIX")"
  echo "external programs started (xtrace): api.sh=$(forks_of "$SC/api.sh" get teams "$TEAM" members) send.sh=$(forks_of "$SC/send.sh" "$TEAM" tester powers-measure "s6 count") join.sh=$(forks_of "$SC/join.sh" "$TEAM" "s6-count" agmsg-app "$(nat "$FIX")")" | tee -a "$OUT/s6.log"
) 2>>"$OUT/s6.err"
mark_session "S6 after"
verdict PASS S6-scripts "script timings recorded in s6.log (information, no threshold)"

# ---- S7 the startup check of the release build, repeated: does it ever time out on this machine, and why
for i in 1 2 3 4 5; do
  b=$OUT/base-s7-$i; seed_base "$b" || { verdict FAIL "S7-$i" "could not seed the base"; continue; }
  run_for "S7-$i" "$REL" "$OUT/s7-$i.log" 70 -- AGMSG_APP_BASE="$(nat "$b")"
  l=$(grep -F '[addons] startup check:' "$OUT/s7-$i.log" | tail -1)
  if echo "$l" | grep -q 'enabled=true'; then verdict PASS "S7-$i" "release startup check passed"; else verdict FAIL "S7-$i" "release startup check: ${l:-<none>}; refusals: $(grep -c 'refused:' "$OUT/s7-$i.log")"; fi
done

# ---- wrap up (the real-home guard, counts and archive come from finish, which also runs on any early exit)
mark_session end
end_run
