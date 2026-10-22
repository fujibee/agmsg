#!/bin/bash
# usage: m1/run.sh <variant> <profile: debug|release> <logname> [wait-seconds]
# Builds the spike app (distinct identifier, so it never forwards to an installed agmsg app),
# runs it against a throwaway AGMSG_APP_BASE, prints the log, then stops only its own PID.
set -u
cd "$(dirname "$0")/.."
. m1/env.sh
variant=$1; profile=$2; name=$3; wait=${4:-18}
if [ -n "${M1_PREBUILT:-}" ]; then
  EXE=$(prebuilt_exe "$variant" "$profile") || exit 2
else
  if [ -n "${M1_MAIN_CSP:-}" ]; then
    export TAURI_CONFIG="$(python3 -c 'import json,os;print(json.dumps({"identifier":"cc.agmsg.m1spike","app":{"security":{"csp":os.environ["M1_MAIN_CSP"]}}}))')"
  else
    export TAURI_CONFIG='{"identifier":"cc.agmsg.m1spike"}'
  fi
  export M1_VARIANT=$variant
  flags="--features tauri/custom-protocol"; [ "$profile" = release ] && flags="$flags --release"
  cargo build $flags 2>&1 | grep -E "^error|Finished"
  EXE=target/$profile/agmsg-app
fi
export M1_SPIKE=1 M1_LOG=$RUN_N/$name.log M1_PAYLOAD=${M1_PAYLOAD:-$(nat "$PWD/m1/payload")} AGMSG_APP_BASE=$RUN_N/base
mkdir -p "$RUN/base"; rm -f "$RUN/$name.log"
"$EXE" > "$RUN/$name.out" 2>&1 &
APP=$!
sleep "$wait"
cat "$RUN/$name.log"
kill $APP 2>/dev/null; command -v taskkill >/dev/null 2>&1 && taskkill //F //IM "$(basename "$EXE")" >/dev/null 2>&1; wait $APP 2>/dev/null
