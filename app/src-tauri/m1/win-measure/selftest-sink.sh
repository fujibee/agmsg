#!/bin/bash
# Pins down how run-win.sh trusts the sink (runs on any Unix shell, with bash stand-ins for the PowerShell sink):
# the final count counts only when the sink confirmed it with this run's token; a stale live value, a dead or
# killed sink, another token or a wrong count never gives a PASS.
cd "$(dirname "$0")" || exit 2
HERE=$(pwd)
T=$(mktemp -d); trap 'for p in $(cat "$T"/spawned 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
mkdir -p "$T/stubs"
export STUB_MAP="$T/map"; : > "$STUB_MAP"
cat > "$T/stubs/tasklist" <<'S'
#!/bin/bash
if [ "$1" = "//FI" ]; then n=${2#PID eq }; grep "^$n " "$STUB_MAP" | while read -r p i; do echo "\"$i\",\"$p\""; done; fi
S
cat > "$T/stubs/taskkill" <<'S'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
while [ $# -gt 0 ]; do if [ "$1" = "//PID" ]; then kill "$2" 2>/dev/null; fi; shift; done
S
chmod +x "$T/stubs/"*; export PATH="$T/stubs:$PATH" STUB_LOG="$T/kill.log"
. "$HERE/sink.sh"
verdict() { echo "$1 $2 $3" > "$T/verdict"; }
export SINK_FINAL_POLLS=3
bad=0; ok() { echo "ok   $1"; }; no() { echo "WRONG $1"; bad=1; }
case_dir() { SINK="$T/$1/hits.txt"; mkdir -p "$T/$1"; SINK_TOKEN="tok-$1-$RANDOM"; SINK_STOPPED=0; : > "$T/verdict"; : > "$STUB_LOG"; rm -f "$SINK" "$SINK.final" "$SINK.stop" "$SINK.pid"; }
# fake sink: counts "udp=$1 tcp=$2" live; at the stop file it publishes the final line given by $3 ("tok" = this run's token)
fake_sink() { # fake_sink <udp> <tcp> <final mode: good|none|other-token|raw:<text>>
  local u=$1 t=$2 mode=$3 S=$SINK
  ( echo "udp=$u tcp=$t" > "$S"
    while [ ! -s "$S.stop" ]; do sleep 0.1; done
    tok=$(cat "$S.stop")
    case "$mode" in good) echo "$tok udp=$u tcp=$t" > "$S.final" ;; other-token) echo "old-token udp=$u tcp=$t" > "$S.final" ;; raw:*) echo "${mode#raw:}" > "$S.final" ;; none) : ;; esac
  ) & echo $! > "$T/spawned"; sleep 0.3
}
result() { cut -d' ' -f1 "$T/verdict"; }

case_dir good; fake_sink 1 1 good; stop_sink; sink_verdict
[ "$(result)" = PASS ] && ok "a confirmed 1/1 final passes" || no "confirmed 1/1: $(cat "$T/verdict")"

case_dir stale; fake_sink 1 1 none; stop_sink; sink_verdict
[ "$(result)" = FAIL ] && grep -q "did not confirm" "$T/verdict" && ok "a stale live 1/1 with no final fails (publish failed)" || no "stale live value: $(cat "$T/verdict")"

case_dir died; echo "udp=1 tcp=1" > "$SINK"; stop_sink; sink_verdict
[ "$(result)" = FAIL ] && ok "a sink that died early (only the control count left) fails" || no "dead sink: $(cat "$T/verdict")"

case_dir token; fake_sink 1 1 other-token; stop_sink; sink_verdict
[ "$(result)" = FAIL ] && ok "a final with another run's token fails" || no "other token: $(cat "$T/verdict")"

case_dir more; fake_sink 2 1 good; stop_sink; sink_verdict
[ "$(result)" = FAIL ] && grep -q "udp=2 tcp=1" "$T/verdict" && ok "a confirmed count above the control fails and names it" || no "extra hit: $(cat "$T/verdict")"

case_dir garbage; fake_sink 1 1 "raw:udp=1 tcp=1"; stop_sink; sink_verdict
[ "$(result)" = FAIL ] && ok "a final line without the token fails" || no "no token: $(cat "$T/verdict")"

case_dir killed; fake_sink 1 1 none; sp=$(cat "$T/spawned"); echo "$sp" > "$SINK.pid"; echo "$sp powershell.exe" > "$STUB_MAP"
stop_sink; sink_verdict
[ "$(result)" = FAIL ] && grep -q "//PID $sp" "$STUB_LOG" && ok "a sink that had to be killed fails, and only its own id was killed" || no "forced kill: $(cat "$T/verdict") / $(cat "$STUB_LOG")"

# the end of a run: one path for normal and early exits, and the archive line is in the archived summary
grep -q "^trap end_run EXIT" run-win.sh && ok "the exit trap is end_run" || no "trap is not end_run"
awk '/echo "archive: /{a=NR} /make_archive$/{t=NR} END{exit !(a && t && a<t)}' run-win.sh && ok "the archive line is written before the archive is made" || no "archive line after the archive"
. "$HERE/archive.sh"
# the final name appears only when tar has finished: a slow tar is watched, a failing tar leaves no final name
mkdir -p "$T/ar/out"; echo x > "$T/ar/out/f"; OUT="$T/ar/out"; SUM="$T/ar/summary.txt"; : > "$SUM"
cat > "$T/stubs/tar" <<'S'
#!/bin/bash
# stand-in tar: writes the file named after "czf", slowly, or fails when STUB_TAR_FAIL is set
f=$2; echo partial > "$f"; sleep 1; [ -n "${STUB_TAR_FAIL:-}" ] && exit 1; echo complete >> "$f"
S
chmod +x "$T/stubs/tar"
make_archive & mp=$!; echo "$mp" >> "$T/spawned"
sleep 0.4
if [ ! -e "$OUT.tgz" ] && [ -e "$OUT.tgz.partial" ]; then ok "while tar still writes there is no final name"; else no "final name present during tar"; fi
wait "$mp"
[ -e "$OUT.tgz" ] && [ ! -e "$OUT.tgz.partial" ] && grep -q complete "$OUT.tgz" && ok "the final name appears, complete, when tar succeeded" || no "no complete archive after success"
rm -f "$OUT.tgz"
STUB_TAR_FAIL=1 make_archive > /dev/null 2>&1
[ ! -e "$OUT.tgz" ] && grep -q "^FAIL archive" "$SUM" && ok "a failing tar makes no final name and reports FAIL" || no "failing tar: $(ls "$T/ar"; cat "$SUM")"
[ "$(grep -c 'run ended' run-win.sh)" = 1 ] && ok "one end note" || no "end note count"
# end_run, taken from run-win.sh as written, runs its steps once whether the normal end and the trap both call it or not
eval "$(awk '/^ENDED=0/{f=1} f{print} f&&/^}/{exit}' run-win.sh)"
calls="$T/endcalls"; : > "$calls"
stop_sink() { echo stop_sink >> "$calls"; }; stop_launched() { echo stop_launched >> "$calls"; }; note() { echo note >> "$calls"; }
snapshot() { echo snap; }; make_archive() { echo archive >> "$calls"; }
OUT="$T/endout"; mkdir -p "$OUT"; echo b > "$OUT/real-home-before.txt"; SUM="$T/end.sum"; : > "$SUM"
verdict() { :; }
end_run > /dev/null; end_run > /dev/null   # the normal end, then the exit trap
[ "$(grep -c . "$calls")" = 4 ] && [ "$(grep -c '^archive$' "$calls")" = 1 ] && [ "$(grep -c '^note$' "$calls")" = 1 ] && ok "end_run runs once even when called twice (normal end + trap)" || no "end_run calls: $(tr '\n' ' ' < "$calls")"
grep -q 'archive.tgz.partial\|\.tgz\.partial' archive.sh && ! grep -q 'tgz.partial.*\$OUT/' archive.sh && ok "the temporary archive name is outside the output folder" || no "temporary name inside OUT"

[ "$bad" = 0 ] && echo "selftest-sink: all expectations hold" || { echo "selftest-sink: FAILED"; exit 1; }
