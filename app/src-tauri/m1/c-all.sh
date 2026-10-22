#!/bin/bash
# usage: m1/c-all.sh <variant> <profile> <tag>   - runs every C group with and without network, one launch per group
cd "$(dirname "$0")/.."
. m1/env.sh
export M1_CSP="$(m1/csp.sh)"
for net in 0 1; do
  for g in net1 net2 css webrtc run1 run2; do
    M1_NET=$net M1_ENTRY="c.html#$g" m1/run.sh "$1" "$2" "$3-net$net-$g" 11 > /dev/null 2>&1
  done
done
echo finished > $RUN/$3.done
