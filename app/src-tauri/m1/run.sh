#!/bin/bash
# usage: m1/run.sh <variant> <profile: debug|release> <logname> [wait-seconds]
# Builds the spike app (distinct identifier, so it never forwards to an installed agmsg app),
# runs it against a throwaway AGMSG_APP_BASE, prints the log, then stops only its own PID.
set -u
cd "$(dirname "$0")/.."
variant=$1; profile=$2; name=$3; wait=${4:-18}
export TAURI_CONFIG='{"identifier":"cc.agmsg.m1spike"}' M1_VARIANT=$variant
flags="--features tauri/custom-protocol"; [ "$profile" = release ] && flags="$flags --release"
cargo build $flags 2>&1 | grep -E "^error|Finished" 
export M1_SPIKE=1 M1_LOG=/tmp/m1run/$name.log M1_PAYLOAD=${M1_PAYLOAD:-$PWD/m1/payload} AGMSG_APP_BASE=/tmp/m1run/base
mkdir -p "$AGMSG_APP_BASE"; rm -f "$M1_LOG"
target/$profile/agmsg-app > /tmp/m1run/$name.out 2>&1 &
APP=$!
sleep "$wait"
cat "$M1_LOG"
kill $APP 2>/dev/null; wait $APP 2>/dev/null
