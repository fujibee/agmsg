#!/bin/bash
# Pins down the process rules of run-win.sh with stand-ins for tasklist and taskkill (runs on any Unix shell):
#   - another run's executables present: exit 3 and not one taskkill call
#   - a normal run stops only the process ids it launched, by PID, never by image name
#   - an id that no longer belongs to the launched image is left alone
cd "$(dirname "$0")" || exit 2
HERE=$(pwd)
T=$(mktemp -d); trap 'for p in $(cat "$T"/spawned 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
mkdir -p "$T/stubs" "$T/bin"
export STUB_LOG="$T/taskkill.log" STUB_MAP="$T/map" STUB_TASKS="$T/tasks"
: > "$STUB_LOG"; : > "$STUB_MAP"; : > "$STUB_TASKS"
cat > "$T/stubs/tasklist" <<'S'
#!/bin/bash
# tasklist [//FI "PID eq N" //FO CSV //NH]: from the map "pid image" for a PID query, else the plain list
if [ "$1" = "//FI" ]; then n=${2#PID eq }; grep "^$n " "$STUB_MAP" | while read -r p i; do echo "\"$i\",\"$p\""; done; else cat "$STUB_TASKS"; fi
S
cat > "$T/stubs/taskkill" <<'S'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
while [ $# -gt 0 ]; do if [ "$1" = "//PID" ]; then kill "$2" 2>/dev/null; fi; shift; done
S
chmod +x "$T/stubs/tasklist" "$T/stubs/taskkill"
fake_exe() { printf '#!/bin/bash\nexec sleep 120\n' > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
fake_exe agmsg-app-win-measure-debug.exe; fake_exe agmsg-app-win-measure-release.exe
bad=0
ok() { echo "ok   $1"; }
no() { echo "WRONG $1"; bad=1; }
export PATH="$T/stubs:$PATH"

# 1. another run is present: the real run script must exit 3 without a single taskkill
echo '"agmsg-app-win-measure-debug.exe","4242"' > "$STUB_TASKS"
mkdir -p "$T/binarg"
bash "$HERE/run-win.sh" "$T/binarg" "$T/out1" > "$T/run1.out" 2>&1; code=$?
[ "$code" = 3 ] && ok "exit 3 when another run's executable is present" || no "exit code $code, wanted 3"
[ ! -s "$STUB_LOG" ] && ok "no taskkill call at all in that case" || no "taskkill was called: $(cat "$STUB_LOG")"
grep -q "already running" "$T/run1.out" && ok "the refusal is reported" || no "no refusal message"
: > "$STUB_TASKS"

# 2. a normal run: launch two, with an unrelated process of the same image name present
export TRACK="$T/pids.txt"; : > "$TRACK"
. "$HERE/procs.sh"
other_run_present && no "nothing running yet but other_run_present said yes" || ok "no other run when the task list is empty"
sleep 120 & other=$!; echo "$other" >> "$T/spawned"
echo "$other agmsg-app-win-measure-debug.exe" >> "$STUB_MAP"      # looks like another run's debug exe
launch "$T/a.log" "$T/bin/agmsg-app-win-measure-debug.exe" X=1
launch "$T/b.log" "$T/bin/agmsg-app-win-measure-release.exe" Y=2
sleep 1
mine=$(awk '{print $1}' "$TRACK" | tr '\n' ' ')
for p in $mine; do echo "$p $(grep -F " " "$TRACK" | awk -v p=$p '$1==p{print $2}')" >> "$STUB_MAP"; echo "$p" >> "$T/spawned"; done
: > "$STUB_LOG"
stop_launched
grep -q -- '//IM' "$STUB_LOG" && no "taskkill by image name was used" || ok "never kills by image name"
for p in $mine; do kill -0 "$p" 2>/dev/null && no "launched process $p survived" || ok "launched process $p stopped"; done
kill -0 "$other" 2>/dev/null && ok "the unrelated process with the same image name is untouched" || no "the unrelated process was killed"
[ "$(grep -c . "$STUB_LOG")" = 2 ] && ok "exactly two taskkill calls, both by PID" || no "taskkill calls: $(cat "$STUB_LOG")"

# 3. a recorded id that now belongs to another image is left alone
sleep 120 & reuse=$!; echo "$reuse" >> "$T/spawned"
echo "$reuse agmsg-app-win-measure-debug.exe" > "$TRACK"
echo "$reuse notepad.exe" > "$STUB_MAP"
: > "$STUB_LOG"
stop_launched
kill -0 "$reuse" 2>/dev/null && [ ! -s "$STUB_LOG" ] && ok "a reused id is not killed" || no "reused id handling: $(cat "$STUB_LOG")"

[ "$bad" = 0 ] && echo "selftest-procs: all expectations hold" || { echo "selftest-procs: FAILED"; exit 1; }
